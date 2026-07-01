// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Constants} from "./models/Constant.sol";

/**
 * @title Lendbit VTokenVault
 * @author Lendbit Protocol
 * @notice ERC4626-compliant tokenized vault for Lendbit Protocol
 * @dev This vault integrates with the lending protocol to provide yield-bearing tokens
 */
contract TokenVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Custom errors
    error InvalidAddressZero();
    error InvalidAmount();
    error InvalidRate();
    error VaultPaused();
    error OnlyDiamond();
    error InsufficientShares();
    error InsufficientBalance();
    error TransferNotAllowed();
    error NotWETHVault();
    error ETHTransferFailed();
    error TransferFailed();
    error OnlyWETHContract();

    uint16 private interestRate;
    /// @notice Protocol's share of interest, in bps, kept in sync with the
    ///         token's `reserveFactor`. Interest accrues to LPs NET of this.
    uint16 private reserveFactor;
    uint256 private totalBorrows;
    /// @dev LP-claimable accrued interest (already NET of the reserve factor).
    uint256 private totalAccruedInterest;
    /// @notice Protocol's realized interest reserve, claimable by the diamond.
    uint256 public totalProtocolReserve;
    /// @dev purely historical metric, NOT used in valuation
    uint256 private totalBadDebt;

    /// @notice Protocol diamond address
    address public immutable diamond;

    /// @notice Last update timestamp
    uint256 public lastUpdateTimestamp;

    /// @notice Boolean indicating if vault is paused
    bool public paused;

    /// @dev Only diamond modifier
    modifier onlyDiamond() {
        _onlyDiamond();
        _;
    }

    function _onlyDiamond() internal view {
        if (msg.sender != diamond) revert OnlyDiamond();
    }

    /// @dev Not paused modifier
    modifier notPaused() {
        _notPaused();
        _;
    }

    function _notPaused() internal view {
        if (paused) revert VaultPaused();
    }

    /// @dev Address zero check modifier
    modifier addressZeroCheck(address _addr) {
        _addressZeroCheck(_addr);
        _;
    }

    function _addressZeroCheck(address _addr) internal pure {
        if (_addr == address(0)) revert InvalidAddressZero();
    }

    /// @dev Valid amount check modifier
    modifier validAmount(uint256 _amount) {
        _validAmount(_amount);
        _;
    }

    function _validAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount();
    }

    /**
     * @notice Construct a new VToken vault
     * @param _asset Underlying asset (use WETH address for ETH vaults)
     * @param _name Name of the vault token
     * @param _symbol Symbol of the vault token
     * @param _diamond Diamond contract address
     */
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _diamond,
        uint16 _interestRate,
        uint16 _reserveFactor
    )
        ERC4626(IERC20(_asset))
        ERC20(_name, _symbol)
        addressZeroCheck(_asset)
        addressZeroCheck(_diamond)
    {
        diamond = _diamond;
        lastUpdateTimestamp = block.timestamp;
        interestRate = _interestRate;
        reserveFactor = _reserveFactor;
    }

    /**
     * @notice Set pause state (only diamond)
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyDiamond {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    /**
     * @notice Get total assets managed by the vault
     * @return Total amount of underlying assets
     */
    /// @dev Time-weighted accrual: LP share value grows smoothly as interest
    ///      accrues on outstanding principal (so a late depositor only earns
    ///      interest accrued after they join). `totalAccruedInterest` and the
    ///      pending bucket are NET of the reserve factor; the protocol's realized
    ///      reserve is excluded.
    function totalAssets() public view override returns (uint256) {
        uint256 _interest = _pendingInterest();
        uint256 _balance = IERC20(asset()).balanceOf(address(this));

        return _balance + totalBorrows + totalAccruedInterest + _interest - totalProtocolReserve;
    }

    /**
     * @notice Deposit ERC20 assets into the vault
     * @param assets Amount of assets to deposit
     * @param receiver Address receiving the shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        onlyDiamond
        notPaused
        addressZeroCheck(receiver)
        validAmount(assets)
        returns (uint256 shares)
    {
        // accrue interest up to now (non-compounding)
        _accrueInterest();

        // Calculate shares (based on snapshot after accrual, before transfer)
        shares = previewDeposit(assets);
        if (shares == 0) revert InvalidAmount();

        // Transfer assets from sender to this vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // Mint shares to receiver
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /**
     * @notice Withdraw ERC20 assets from the vault
     * @param assets Amount of assets to withdraw
     * @param receiver Address receiving the assets
     * @param owner Owner of the shares
     * @return shares Amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        onlyDiamond
        addressZeroCheck(receiver)
        addressZeroCheck(owner)
        validAmount(assets)
        returns (uint256 shares)
    {
        // accrue interest up to now (non-compounding)
        _accrueInterest();

        // Calculate shares needed
        shares = previewWithdraw(assets);
        if (shares == 0) revert InvalidAmount();

        // Check if owner has enough shares
        if (balanceOf(owner) < shares) revert InsufficientShares();

        // Check allowance if a third party is spending the owner's shares. The
        // diamond is exempt: `withdraw` is `onlyDiamond`, and the diamond's
        // `_withdraw` already pins `owner` to the calling depositor, so it never
        // moves another user's shares — a separate user→diamond share approval
        // would otherwise be required and the deposit flow never grants it (#7).
        if (msg.sender != owner && msg.sender != diamond) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // only the non-reserve liquid balance is withdrawable by LPs
        uint256 _balance = IERC20(asset()).balanceOf(address(this));
        if (_balance - totalProtocolReserve < assets) {
            revert InsufficientBalance();
        }

        // Burn shares first
        _burn(owner, shares);

        // Transfer assets to receiver
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    /// @dev The inherited ERC4626 `mint`/`redeem` are gated behind `onlyDiamond`
    ///      so that ALL vault entry/exit flows through the diamond's accounting
    ///      (`config.totalDeposits`, position/pause/reserve checks). Otherwise a
    ///      shareholder could `redeem` directly and desync that accounting (#3).
    /// @notice Mint an exact number of shares to a receiver, pulling the
    ///         corresponding assets from the caller via the inherited ERC4626 flow.
    /// @param shares Amount of shares to mint.
    /// @param receiver Address receiving the minted shares.
    /// @return Amount of assets deposited for the minted shares.
    function mint(uint256 shares, address receiver) public override onlyDiamond returns (uint256) {
        return super.mint(shares, receiver);
    }

    /// @notice Burn an exact number of shares from an owner and return the
    ///         corresponding assets to the receiver via the inherited ERC4626 flow.
    /// @param shares Amount of shares to burn.
    /// @param receiver Address receiving the redeemed assets.
    /// @param owner Owner of the shares being burned.
    /// @return Amount of assets returned for the redeemed shares.
    function redeem(uint256 shares, address receiver, address owner) public override onlyDiamond returns (uint256) {
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Lend assets out of the vault to a borrower (only diamond).
    /// @dev Accrues interest, increases `totalBorrows` by `amount`, and transfers
    ///      `amount` of the underlying asset out — reverting if the non-reserve
    ///      liquid balance is insufficient.
    /// @param receiver Address receiving the borrowed assets.
    /// @param amount Principal amount to lend out.
    function borrow(address receiver, uint256 amount) external onlyDiamond {
        // accrue interest into non-compounding bucket
        _accrueInterest();

        // increase principal borrows (non-compounding)
        totalBorrows = totalBorrows + amount;

        // only the non-reserve liquid balance can be lent out
        if (IERC20(asset()).balanceOf(address(this)) - totalProtocolReserve < amount) revert InsufficientBalance();

        // transfer funds out
        IERC20(asset()).safeTransfer(receiver, amount);

        emit Borrow(_msgSender(), amount);
    }

    /// @notice Book a repayment, split by the diamond into principal and interest.
    /// @dev `principalRepaid` reduces outstanding principal; the interest is split
    ///      by the reserve factor — the LP share realizes the smoothly-accrued
    ///      receivable (keeping totalAssets continuous), the protocol share lands
    ///      in the claimable reserve. The diamond has already transferred the full
    ///      principal + interest into the vault.
    /// @param principalRepaid Principal portion of the repayment.
    /// @param interestPaid    Interest (incl. penalty) portion of the repayment.
    function repay(uint256 principalRepaid, uint256 interestPaid) external onlyDiamond {
        _accrueInterest();

        if (principalRepaid >= totalBorrows) {
            totalBorrows = 0;
        } else {
            totalBorrows = totalBorrows - principalRepaid;
        }

        uint256 _reserve = (interestPaid * reserveFactor) / Constants.BASIS_POINTS_SCALE_256;
        uint256 _lpInterest = interestPaid - _reserve;

        if (_lpInterest >= totalAccruedInterest) {
            totalAccruedInterest = 0;
        } else {
            totalAccruedInterest = totalAccruedInterest - _lpInterest;
        }
        totalProtocolReserve = totalProtocolReserve + _reserve;

        emit Repay(_msgSender(), principalRepaid + interestPaid);
    }

    /**
     * @notice Mint shares for a user (only diamond)
     * @param receiver Address to mint shares for
     * @param shares Amount of shares to mint
     */
    function mintFor(address receiver, uint256 shares)
        external
        onlyDiamond
        addressZeroCheck(receiver)
        validAmount(shares)
    {
        _mint(receiver, shares);
    }

    /**
     * @notice Burn shares from a user (only diamond)
     * @param owner Address to burn shares from
     * @param shares Amount of shares to burn
     */
    function burnFor(address owner, uint256 shares) external onlyDiamond addressZeroCheck(owner) validAmount(shares) {
        if (balanceOf(owner) < shares) revert InsufficientShares();
        _burn(owner, shares);
    }

    /// @notice Keep the vault's accrual rate in sync with the protocol's rate.
    /// @dev The diamond pushes its current rate so depositor accrual tracks what
    ///      borrowers actually pay (the fix for the frozen-rate decoupling). Bound
    ///      is the diamond's responsibility; accrue first so the change is applied
    ///      only going forward.
    /// @param rate New annual interest rate, in basis points.
    function setInterestRate(uint16 rate) external onlyDiamond {
        _accrueInterest();
        interestRate = rate;
        emit InterestRateSet(rate);
    }

    /// @notice Keep the vault's reserve factor in sync with the token config.
    /// @dev Accrues interest before the change so the new factor applies only going
    ///      forward. Reverts if `_reserveFactor` exceeds the basis-point scale.
    /// @param _reserveFactor New protocol reserve factor, in basis points.
    function setReserveFactor(uint16 _reserveFactor) external onlyDiamond {
        if (_reserveFactor > Constants.BASIS_POINTS_SCALE) revert InvalidRate();
        _accrueInterest();
        reserveFactor = _reserveFactor;
        emit ReserveFactorSet(_reserveFactor);
    }

    /// @notice Transfer realized protocol reserve out of the vault (only diamond).
    /// @param to Address receiving the withdrawn reserve.
    /// @param amount Amount of reserve to withdraw; reverts if it exceeds `totalProtocolReserve`.
    function withdrawReserve(address to, uint256 amount)
        external
        onlyDiamond
        addressZeroCheck(to)
        validAmount(amount)
    {
        if (amount > totalProtocolReserve) revert InvalidAmount();
        totalProtocolReserve = totalProtocolReserve - amount;
        IERC20(asset()).safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    /// @notice The protocol's currently-claimable interest reserve.
    /// @return The current `totalProtocolReserve` value.
    function protocolReserve() external view returns (uint256) {
        return totalProtocolReserve;
    }

    /// @notice Record bad debt and write it off the vault's borrow base (only diamond).
    /// @dev Accrues interest, then writes off `amount` first against `totalBorrows`
    ///      (principal) and any remainder against `totalAccruedInterest`, which
    ///      lowers `totalAssets` and the share price. `totalBadDebt` tracks the
    ///      cumulative written-off amount. Reverts if `amount` exceeds outstanding
    ///      principal plus accrued interest.
    /// @param amount Bad-debt amount to write off.
    function updateBadDebt(uint256 amount) external onlyDiamond validAmount(amount) {
        // accrue interest before updating bad debt
        _accrueInterest();

        uint256 _totalBorrowedWithInterest = totalBorrows + totalAccruedInterest;

        // Validate bad debt amount doesn't exceed total borrowed amount + accrued interest
        if (amount > _totalBorrowedWithInterest) {
            revert InvalidAmount();
        }

        // increase bad debt (reduces totalAssets)
        totalBadDebt = totalBadDebt + amount;

        // Write off bad debt: first from principal, then from accrued interest
        uint256 _remainingBadDebt = amount;

        if (_remainingBadDebt >= totalBorrows) {
            // Write off entire principal
            _remainingBadDebt = _remainingBadDebt - totalBorrows;
            totalBorrows = 0;
        } else {
            // Partial write-off from principal
            totalBorrows = totalBorrows - _remainingBadDebt;
            _remainingBadDebt = 0;
        }

        // Write off remaining bad debt from accrued interest
        if (_remainingBadDebt > 0) {
            if (_remainingBadDebt >= totalAccruedInterest) {
                totalAccruedInterest = 0;
            } else {
                totalAccruedInterest = totalAccruedInterest - _remainingBadDebt;
            }
        }

        emit BadDebtUpdated(amount, totalBadDebt);
    }

    function _accrueInterest() internal {
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        if (timeElapsed == 0) return;

        uint256 lpInterest = _pendingInterest();
        if (lpInterest > 0) {
            totalAccruedInterest += lpInterest;
        }

        lastUpdateTimestamp = block.timestamp;
    }

    /// @dev LP's share of the interest accrued since the last update (net of the
    ///      reserve factor). The protocol's slice is realized into the reserve at
    ///      repayment, keeping totalAssets smooth across a repayment.
    function _pendingInterest() internal view returns (uint256) {
        uint256 _timeElapsed = block.timestamp - lastUpdateTimestamp;
        uint256 _gross =
            (totalBorrows * interestRate * _timeElapsed) / (Constants.BASIS_POINTS_SCALE_256 * Constants.ONE_YEAR);
        return (_gross * (Constants.BASIS_POINTS_SCALE_256 - reserveFactor)) / Constants.BASIS_POINTS_SCALE_256;
    }

    /// @notice The vault's outstanding principal borrows (excludes accrued interest).
    /// @return The current `totalBorrows` value.
    function totalBorrow() external view returns (uint256) {
        return totalBorrows;
    }

    // Events
    event PausedStateChanged(bool paused);
    event ExchangeRateUpdated(uint256 newRate);
    event BadDebtUpdated(uint256 amount, uint256 totalBadDebt);
    event Borrow(address indexed to, uint256 amount);
    event Repay(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event InterestRateSet(uint16 rate);
    event ReserveFactorSet(uint16 reserveFactor);
}
