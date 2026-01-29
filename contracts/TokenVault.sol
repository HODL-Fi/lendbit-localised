// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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
    error InvalidRateCanOnlyIncrease();
    error InvalidAmount();
    error VaultPaused();
    error OnlyDiamond();
    error InsufficientShares();
    error InsufficientBalance();
    error TransferNotAllowed();
    error NotWETHVault();
    error ETHTransferFailed();
    error TransferFailed();
    error OnlyWETHContract();

    /// @notice Protocol diamond address
    address public immutable diamond;

    /// @notice Exchange rate when last updated (asset per share, scaled by 1e18)
    uint256 public exchangeRateStored;

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
    constructor(address _asset, string memory _name, string memory _symbol, address _diamond)
        ERC4626(IERC20(_asset))
        ERC20(_name, _symbol)
        addressZeroCheck(_asset)
        addressZeroCheck(_diamond)
    {
        diamond = _diamond;
        exchangeRateStored = 1e18; // Initialize at 1:1
        lastUpdateTimestamp = block.timestamp;
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
        return IERC20(asset()).balanceOf(address(this));
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
        notPaused
        addressZeroCheck(receiver)
        validAmount(assets)
        returns (uint256 shares)
    {
        // Calculate shares
        shares = convertToShares(assets);
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
        addressZeroCheck(receiver)
        addressZeroCheck(owner)
        validAmount(assets)
        returns (uint256 shares)
    {
        // Calculate shares needed
        shares = convertToShares(assets);
        if (shares == 0) revert InvalidAmount();

        // Check allowance if not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Check if owner has enough shares
        if (balanceOf(owner) < shares) revert InsufficientShares();

        // Burn shares first
        _burn(owner, shares);

        // Transfer assets to receiver
        bool success = IERC20(asset()).transfer(receiver, assets);
        if (!success) revert TransferFailed();

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function borrow(address receiver, uint256 amount) external onlyDiamond {
        IERC20 token = IERC20(asset());
        if (token.balanceOf(address(this)) < amount) revert InsufficientBalance();

        bool success = token.transfer(receiver, amount);
        if (!success) revert TransferFailed();
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

    // Events
    event PausedStateChanged(bool paused);
    event ExchangeRateUpdated(uint256 newRate);
}
