// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {TokenVault} from "./TokenVault.sol";

// ---------------------------------------------------------------------------
// Minimal interface into the Lendbit Diamond
// ---------------------------------------------------------------------------

interface ILendbitDiamond {
    /// @notice VaultManagerFacet — deposits `_amount` of `_token` on behalf of caller
    function deposit(address _token, uint256 _amount) external returns (uint256 shares);

    /// @notice VaultManagerFacet — withdraws `_amount` of `_token` and sends to caller
    function withdraw(address _token, uint256 _amount) external;

    /// @notice GettersFacet — returns the TokenVault address for a given token
    function getTokenVault(address _token) external view returns (address);
}

// ---------------------------------------------------------------------------
// TimeLockVault
// ---------------------------------------------------------------------------

/**
 * @title  TimeLockVault
 * @author Lendbit Protocol
 * @notice Standalone time-based fund-locking wrapper around the Lendbit protocol.
 *
 *         Users deposit ERC-20 tokens for a fixed lock duration. While locked,
 *         the underlying assets earn yield inside the protocol's TokenVault (ERC-4626).
 *         Vault shares are custodied by this contract on behalf of each user.
 *
 *         On expiry the user calls `withdraw()` and receives their original assets
 *         plus any accrued yield.
 *
 *         Early withdrawal is permitted subject to a penalty (default 5 %) that is
 *         deducted from the redeemable assets and sent to the contract owner.
 *
 * @dev    Flow:
 *         deposit() ──► diamond.deposit() ──► TokenVault.deposit() ──► shares minted to THIS contract
 *         withdraw() ──► diamond.withdraw() ──► TokenVault.withdraw() ──► assets sent to user (minus penalty if early)
 */
contract TimeLockVault is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint16 public constant MAX_PENALTY_BPS = 3000; // 30 % hard cap
    uint256 public constant BASIS_POINTS = 10_000;

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// @notice The Lendbit diamond proxy address
    address public immutable diamond;

    /// @notice Early-withdrawal penalty in basis points (default 500 = 5 %)
    uint16 public penaltyBps;

    /// @notice Minimum lock duration in seconds (default 1 day)
    uint256 public minLockDuration;

    /// @notice Monotonically incrementing lock position counter
    uint256 private s_nextLockId;

    // -----------------------------------------------------------------------
    // Data structures
    // -----------------------------------------------------------------------

    struct LockPosition {
        address owner;      // user who created the lock
        address token;      // ERC-20 token address
        uint256 assets;     // original deposited asset amount
        uint256 shares;     // vault shares held by this contract for the user
        uint256 lockExpiry; // unix timestamp after which free withdrawal is permitted
        bool withdrawn;     // true once the position has been closed
    }

    // lockId => LockPosition
    mapping(uint256 => LockPosition) private s_lockPositions;

    // user => list of lockIds they own
    mapping(address => uint256[]) private s_userLockIds;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Locked(
        address indexed user,
        address indexed token,
        uint256 indexed lockId,
        uint256 assets,
        uint256 shares,
        uint256 lockExpiry
    );

    event Unlocked(
        address indexed user,
        address indexed token,
        uint256 indexed lockId,
        uint256 assetsReceived,
        uint256 shares
    );

    event EarlyUnlocked(
        address indexed user,
        address indexed token,
        uint256 indexed lockId,
        uint256 assetsReceived,
        uint256 penaltyAmount,
        uint256 shares
    );

    event PenaltyUpdated(uint16 oldPenaltyBps, uint16 newPenaltyBps);
    event MinLockDurationUpdated(uint256 oldDuration, uint256 newDuration);

    // -----------------------------------------------------------------------
    // Custom errors
    // -----------------------------------------------------------------------

    error InvalidAmount();
    error InvalidToken();
    error InvalidLockDuration(uint256 given, uint256 minimum);
    error LockNotExpired(uint256 lockId, uint256 expiry, uint256 current);
    error AlreadyWithdrawn(uint256 lockId);
    error NotLockOwner(uint256 lockId, address caller);
    error PenaltyTooHigh(uint16 given, uint16 maximum);
    error ZeroDurationNotAllowed();

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /**
     * @param _diamond      Address of the Lendbit diamond proxy
     * @param _penaltyBps   Initial early-withdrawal penalty in basis points (e.g. 500 = 5 %)
     * @param _minLockDuration  Minimum lock duration in seconds (e.g. 1 days)
     * @param _owner        Initial contract owner (receives early-exit penalties)
     */
    constructor(address _diamond, uint16 _penaltyBps, uint256 _minLockDuration, address _owner)
        Ownable(_owner)
    {
        if (_diamond == address(0)) revert InvalidToken();
        if (_penaltyBps > MAX_PENALTY_BPS) revert PenaltyTooHigh(_penaltyBps, MAX_PENALTY_BPS);
        if (_minLockDuration == 0) revert ZeroDurationNotAllowed();

        diamond = _diamond;
        penaltyBps = _penaltyBps;
        minLockDuration = _minLockDuration;
    }

    // -----------------------------------------------------------------------
    // Core user functions
    // -----------------------------------------------------------------------

    /**
     * @notice Deposit tokens into the Lendbit protocol and lock them for `_lockDuration` seconds.
     *
     * @dev    The caller must have pre-approved this contract to spend `_amount` of `_token`.
     *         This contract then approves the diamond and calls `VaultManagerFacet.deposit()`.
     *         Minted shares land in this contract and are recorded against the caller's lock position.
     *
     * @param _token        ERC-20 token to deposit (must be supported by the protocol)
     * @param _amount       Amount of tokens to deposit
     * @param _lockDuration Lock duration in seconds (must be ≥ minLockDuration)
     * @return lockId       The ID of the created lock position
     */
    function deposit(address _token, uint256 _amount, uint256 _lockDuration)
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (_token == address(0)) revert InvalidToken();
        if (_amount == 0) revert InvalidAmount();
        if (_lockDuration < minLockDuration) {
            revert InvalidLockDuration(_lockDuration, minLockDuration);
        }

        // 1. Pull tokens from the user into this contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // 2. Approve the diamond to spend them
        IERC20(_token).approve(diamond, _amount);

        // 3. Call the protocol deposit — shares are minted to THIS contract
        //    because msg.sender to the diamond is address(this)
        uint256 shares = ILendbitDiamond(diamond).deposit(_token, _amount);

        // 4. Record the lock position
        lockId = ++s_nextLockId;
        uint256 expiry = block.timestamp + _lockDuration;

        s_lockPositions[lockId] = LockPosition({
            owner: msg.sender,
            token: _token,
            assets: _amount,
            shares: shares,
            lockExpiry: expiry,
            withdrawn: false
        });

        s_userLockIds[msg.sender].push(lockId);

        emit Locked(msg.sender, _token, lockId, _amount, shares, expiry);
    }

    /**
     * @notice Withdraw funds after the lock period has expired.
     *         The user receives the full redeemable assets (original deposit + yield).
     *
     * @param _lockId   The lock position ID to withdraw from
     */
    function withdraw(uint256 _lockId) external nonReentrant {
        LockPosition storage pos = s_lockPositions[_lockId];

        _assertCanWithdraw(pos, _lockId);

        if (block.timestamp < pos.lockExpiry) {
            revert LockNotExpired(_lockId, pos.lockExpiry, block.timestamp);
        }

        // Compute current redeemable assets (original + yield)
        uint256 redeemableAssets = _convertSharesToAssets(pos.token, pos.shares);

        pos.withdrawn = true;

        // Withdraw from the protocol — assets are sent directly to the user
        // The diamond's withdraw() sends assets to msg.sender (this contract),
        // so we re-route them to the position owner.
        _executeWithdrawToUser(pos.token, redeemableAssets, pos.owner);

        emit Unlocked(msg.sender, pos.token, _lockId, redeemableAssets, pos.shares);
    }

    /**
     * @notice Withdraw funds BEFORE the lock period has expired, subject to a penalty.
     *         The penalty (penaltyBps % of redeemable assets) is transferred to the owner.
     *         The remaining assets are sent to the caller.
     *
     * @param _lockId   The lock position ID to withdraw from early
     */
    function earlyWithdraw(uint256 _lockId) external nonReentrant {
        LockPosition storage pos = s_lockPositions[_lockId];

        _assertCanWithdraw(pos, _lockId);

        // Compute current redeemable assets (original + yield so far)
        uint256 redeemableAssets = _convertSharesToAssets(pos.token, pos.shares);

        // Compute penalty
        uint256 penalty = (redeemableAssets * penaltyBps) / BASIS_POINTS;
        uint256 userAssets = redeemableAssets - penalty;

        pos.withdrawn = true;

        // Withdraw full redeemable amount from the protocol into this contract
        _executeWithdrawToSelf(pos.token, redeemableAssets);

        // Send net amount to user
        IERC20(pos.token).safeTransfer(pos.owner, userAssets);

        // Send penalty to protocol owner
        if (penalty > 0) {
            IERC20(pos.token).safeTransfer(owner(), penalty);
        }

        emit EarlyUnlocked(msg.sender, pos.token, _lockId, userAssets, penalty, pos.shares);
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /**
     * @notice Get all details of a lock position.
     * @param _lockId The lock position ID
     * @return LockPosition struct
     */
    function getPosition(uint256 _lockId) external view returns (LockPosition memory) {
        return s_lockPositions[_lockId];
    }

    /**
     * @notice Get all lock IDs belonging to a user.
     * @param _user The user's address
     * @return Array of lockIds
     */
    function getUserLockIds(address _user) external view returns (uint256[] memory) {
        return s_userLockIds[_user];
    }

    /**
     * @notice Preview the current amount of underlying assets redeemable for
     *         the shares held in a given lock position (includes accrued yield).
     *
     * @param _lockId The lock position ID
     * @return Current redeemable asset amount
     */
    function getRedeemableAssets(uint256 _lockId) external view returns (uint256) {
        LockPosition memory pos = s_lockPositions[_lockId];
        if (pos.owner == address(0) || pos.withdrawn) return 0;
        return _convertSharesToAssets(pos.token, pos.shares);
    }

    /**
     * @notice Returns the total number of lock positions ever created.
     */
    function totalLocks() external view returns (uint256) {
        return s_nextLockId;
    }

    // -----------------------------------------------------------------------
    // Owner admin functions
    // -----------------------------------------------------------------------

    /**
     * @notice Update the early-withdrawal penalty.
     * @param _newPenaltyBps New penalty in basis points. Must not exceed MAX_PENALTY_BPS (30 %).
     */
    function setPenaltyBps(uint16 _newPenaltyBps) external onlyOwner {
        if (_newPenaltyBps > MAX_PENALTY_BPS) {
            revert PenaltyTooHigh(_newPenaltyBps, MAX_PENALTY_BPS);
        }
        emit PenaltyUpdated(penaltyBps, _newPenaltyBps);
        penaltyBps = _newPenaltyBps;
    }

    /**
     * @notice Update the minimum lock duration.
     * @param _newMinDuration New minimum in seconds. Must be > 0.
     */
    function setMinLockDuration(uint256 _newMinDuration) external onlyOwner {
        if (_newMinDuration == 0) revert ZeroDurationNotAllowed();
        emit MinLockDurationUpdated(minLockDuration, _newMinDuration);
        minLockDuration = _newMinDuration;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// @dev Common validation for both withdraw() and earlyWithdraw()
    function _assertCanWithdraw(LockPosition storage pos, uint256 _lockId) internal view {
        if (pos.owner == address(0)) revert NotLockOwner(_lockId, msg.sender);
        if (pos.withdrawn) revert AlreadyWithdrawn(_lockId);
        if (pos.owner != msg.sender) revert NotLockOwner(_lockId, msg.sender);
    }

    /**
     * @dev Convert `_shares` of `_token`'s vault to underlying asset amount.
     *      Fetches the TokenVault address from the diamond's GettersFacet.
     */
    function _convertSharesToAssets(address _token, uint256 _shares)
        internal
        view
        returns (uint256)
    {
        address vaultAddr = ILendbitDiamond(diamond).getTokenVault(_token);
        return TokenVault(vaultAddr).convertToAssets(_shares);
    }

    /**
     * @dev Calls `VaultManagerFacet.withdraw()` which sends assets to msg.sender (this contract).
     *      Used by earlyWithdraw() so this contract can split the assets.
     *
     *      TokenVault.withdraw() burns shares from the `owner` (this contract) via
     *      `_spendAllowance(owner, msg.sender, shares)` where msg.sender is the diamond.
     *      Therefore we must approve the diamond for our share balance first.
     */
    function _executeWithdrawToSelf(address _token, uint256 _assets) internal {
        address vaultAddr = ILendbitDiamond(diamond).getTokenVault(_token);
        uint256 shares = TokenVault(vaultAddr).previewWithdraw(_assets);
        // Approve diamond to spend our shares
        TokenVault(vaultAddr).approve(diamond, shares);
        ILendbitDiamond(diamond).withdraw(_token, _assets);
        // Reset allowance to zero for safety
        TokenVault(vaultAddr).approve(diamond, 0);
    }

    /**
     * @dev Calls `VaultManagerFacet.withdraw()`, approving the diamond for shares first,
     *      then forwards the received assets to `_recipient`.
     */
    function _executeWithdrawToUser(address _token, uint256 _assets, address _recipient) internal {
        address vaultAddr = ILendbitDiamond(diamond).getTokenVault(_token);
        uint256 shares = TokenVault(vaultAddr).previewWithdraw(_assets);
        // Approve diamond to spend our shares
        TokenVault(vaultAddr).approve(diamond, shares);
        ILendbitDiamond(diamond).withdraw(_token, _assets);
        // Reset allowance to zero for safety
        TokenVault(vaultAddr).approve(diamond, 0);
        IERC20(_token).safeTransfer(_recipient, _assets);
    }
}
