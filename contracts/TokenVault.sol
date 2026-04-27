// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

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
    uint256 private totalBorrows;
    uint256 private totalAccruedInterest;
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
    constructor(address _asset, string memory _name, string memory _symbol, address _diamond, uint16 _interestRate)
        ERC4626(IERC20(_asset))
        ERC20(_name, _symbol)
        addressZeroCheck(_asset)
        addressZeroCheck(_diamond)
    {
        diamond = _diamond;
        lastUpdateTimestamp = block.timestamp;
        interestRate = _interestRate;
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
    function totalAssets() public view override returns (uint256) {
        uint256 _interest = _pendingInterest();
        uint256 _balance = IERC20(asset()).balanceOf(address(this));

        return _balance + totalBorrows + totalAccruedInterest + _interest;
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
        onlyDiamond
        nonReentrant
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
        onlyDiamond
        nonReentrant
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

        // Check allowance if not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 _balance = IERC20(asset()).balanceOf(address(this));
        if (_balance < assets) {
            revert InsufficientBalance();
        }

        // Burn shares first
        _burn(owner, shares);

        // Transfer assets to receiver
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function borrow(address receiver, uint256 amount) external onlyDiamond {
        // accrue interest into non-compounding bucket
        _accrueInterest();

        // increase principal borrows (non-compounding)
        totalBorrows = totalBorrows + amount;

        // ensure vault has liquidity to lend
        if (IERC20(asset()).balanceOf(address(this)) < amount) revert InsufficientBalance();

        // transfer funds out
        IERC20(asset()).safeTransfer(receiver, amount);

        emit Borrow(_msgSender(), amount);
    }

    function repay(uint256 amount) external onlyDiamond validAmount(amount) {
        // accrue interest into non-compounding bucket
        _accrueInterest();

        // apply repayment to principal first, then to accrued interest
        if (amount >= totalBorrows) {
            amount = amount - totalBorrows;
            totalBorrows = 0;
        } else {
            totalBorrows = totalBorrows - amount;
            amount = 0;
        }

        if (amount > 0) {
            if (amount >= totalAccruedInterest) {
                amount = amount - totalAccruedInterest;
                totalAccruedInterest = 0;
            } else {
                totalAccruedInterest = totalAccruedInterest - amount;
                amount = 0;
            }
        }

        emit Repay(_msgSender(), amount);
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

    function setInterestRate(uint16 rate) external onlyDiamond {
        if (rate > 10000) revert InvalidRate(); // max 100% interest rate
        _accrueInterest();
        interestRate = rate;
    }

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

        uint256 interest = (totalBorrows * interestRate * timeElapsed) / (Constants.BASIS_POINTS_SCALE_256 * 365 days);

        if (interest > 0) {
            totalAccruedInterest += interest;
        }

        lastUpdateTimestamp = block.timestamp;
    }

    function _pendingInterest() internal view returns (uint256) {
        uint256 _timeElapsed = block.timestamp - lastUpdateTimestamp;
        uint256 _interest = (totalBorrows * interestRate * _timeElapsed) / (Constants.BASIS_POINTS_SCALE_256 * 365 days);
        return _interest;
    }

    function totalBorrow() external view returns (uint256) {
        return totalBorrows;
    }

    // Events
    event PausedStateChanged(bool paused);
    event ExchangeRateUpdated(uint256 newRate);
    event BadDebtUpdated(uint256 amount, uint256 totalBadDebt);
    event Borrow(address indexed to, uint256 amount);
    event Repay(address indexed from, uint256 amount);
}
