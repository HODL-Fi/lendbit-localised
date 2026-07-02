### contracts/Diamond.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import {LibDiamond} from "./libraries/LibDiamond.sol";
import {IDiamondCut} from "./interfaces/IDiamondCut.sol";

/// @title Diamond — EIP-2535 proxy that delegatecalls into registered facets
contract Diamond {
    /// @notice Sets the contract owner and registers the diamondCut function from the supplied DiamondCutFacet.
    /// @param _contractOwner The address granted ownership of the diamond.
    /// @param _diamondCutFacet The facet address whose diamondCut selector is added so the diamond can be upgraded.
    constructor(address _contractOwner, address _diamondCutFacet) payable {
        LibDiamond.setContractOwner(_contractOwner);

        // Add the diamondCut external function from the diamondCutFacet
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: functionSelectors
        });
        LibDiamond.diamondCut(cut, address(0), "");
    }

    // Find facet for function that is called and execute the
    // function if a facet is found and return any value.
    /// @notice Routes any call to the facet registered for the incoming function selector and delegatecalls into it,
    ///         reverting if no facet is registered for the selector.
    fallback() external payable {
        LibDiamond.DiamondStorage storage ds;
        bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;
        // get diamond storage
        assembly {
            ds.slot := position
        }
        // get facet from function selector
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        require(facet != address(0), "Diamond: Function does not exist");
        // Execute external function from facet using delegatecall and return any value.
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    //immutable function example
    /// @notice Returns the hardcoded protocol version string defined directly on the diamond (not on a facet).
    /// @return The version label of the diamond deployment.
    function version() public pure returns (string memory) {
        return "LENDBIT EVOLUTION!!!";
    }

    /// @notice Accepts plain ETH transfers sent to the diamond with no calldata.
    receive() external payable {}
}

```

### contracts/TokenVault.sol

```solidity
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

```

### contracts/facets/DiamondCutFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

/// @title DiamondCutFacet — owner-gated facet that adds, replaces, or removes diamond functions
contract DiamondCutFacet is IDiamondCut {
    /// @notice Add/replace/remove any number of functions and optionally execute
    ///         a function with delegatecall
    /// @param _diamondCut Contains the facet addresses and function selectors
    /// @param _init The address of the contract or facet to execute _calldata
    /// @param _calldata A function call, including function selector and arguments
    ///                  _calldata is executed with delegatecall on _init
    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.diamondCut(_diamondCut, _init, _calldata);
    }
}

```

### contracts/facets/DiamondLoupeFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IERC165} from "../interfaces/IERC165.sol";

/// @title DiamondLoupeFacet — read-only introspection of the diamond's facets and supported interfaces
contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    // Diamond Loupe Functions
    ////////////////////////////////////////////////////////////////////
    /// These functions are expected to be called frequently by tools.
    //
    // struct Facet {
    //     address facetAddress;
    //     bytes4[] functionSelectors;
    // }

    /// @notice Gets all facets and their selectors.
    /// @return facets_ Facet
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numFacets = ds.facetAddresses.length;
        facets_ = new Facet[](numFacets);
        for (uint256 i; i < numFacets; i++) {
            address facetAddress_ = ds.facetAddresses[i];
            facets_[i].facetAddress = facetAddress_;
            facets_[i].functionSelectors = ds.facetFunctionSelectors[facetAddress_].functionSelectors;
        }
    }

    /// @notice Gets all the function selectors provided by a facet.
    /// @param _facet The facet address.
    /// @return facetFunctionSelectors_
    function facetFunctionSelectors(address _facet)
        external
        view
        override
        returns (bytes4[] memory facetFunctionSelectors_)
    {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetFunctionSelectors_ = ds.facetFunctionSelectors[_facet].functionSelectors;
    }

    /// @notice Get all the facet addresses used by a diamond.
    /// @return facetAddresses_
    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddresses_ = ds.facetAddresses;
    }

    /// @notice Gets the facet that supports the given selector.
    /// @dev If facet is not found return address(0).
    /// @param _functionSelector The function selector.
    /// @return facetAddress_ The facet address.
    function facetAddress(bytes4 _functionSelector) external view override returns (address facetAddress_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        facetAddress_ = ds.selectorToFacetAndPosition[_functionSelector].facetAddress;
    }

    // This implements ERC-165.
    /// @notice Reports whether the diamond has registered support for the given ERC-165 interface id.
    /// @param _interfaceId The ERC-165 interface identifier to query.
    /// @return True if the interface id is marked as supported in diamond storage, false otherwise.
    function supportsInterface(bytes4 _interfaceId) external view override returns (bool) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        return ds.supportedInterfaces[_interfaceId];
    }
}

```

### contracts/facets/GettersFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";
import {LibVaultManager} from "../libraries/LibVaultManager.sol";

/// @title GettersFacet — read-only views over collateral, debt, loan, and vault state
contract GettersFacet {
    using LibProtocol for LibAppStorage.StorageLayout;
    using LibVaultManager for LibAppStorage.StorageLayout;

    /**
     * @notice Check if a token is supported as collateral
     * @param _token The token address to check
     * @return bool True if token is supported as collateral
     */
    function isCollateralTokenSupported(address _token) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_supportedCollateralTokens[_token];
    }

    /**
     * @notice Get all supported collateral tokens
     * @return address[] Array of all supported collateral token addresses
     */
    function getAllCollateralTokens() external view returns (address[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_allCollateralTokens;
    }

    /**
     * @notice Get collateral balance for a position and token
     * @param _positionId The position ID
     * @param _token The collateral token address
     * @return uint256 The collateral amount
     */
    function getPositionCollateral(uint256 _positionId, address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_positionCollateral[_positionId][_token];
    }

    /// @notice Return the total USD value of all collateral tokens held by a position.
    /// @param _positionId The position ID
    /// @return The total collateral value in USD
    function getPositionCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionCollateralValue(_positionId);
    }

    /**
     * @notice Get borrowable collateral value for a position based on the LTV of each collateral token and total debt
     * @param _positionId The position ID
     * @return uint256 The borrowable collateral value in USD
     */
    function getPositionBorrowableCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionBorrowableCollateralValue(_positionId);
    }

    /// @notice Return a position's LTV-weighted collateral value in USD (each token's value scaled by its loan-to-value ratio).
    /// @param _positionId The position ID
    /// @return The LTV-weighted (utilizable) collateral value in USD
    function getPositionUtilizableCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionUtilizableCollateralValue(_positionId);
    }

    /// @notice Return the total USD value of a position's open-ended (non-tenured) borrows across all supported tokens, including accrued interest.
    /// @param _positionId The position ID
    /// @return The borrowed value in USD
    function getPositionBorrowedValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionBorrowedValue(_positionId);
    }

    /// @notice Compute a position's health factor (18-decimal ratio of utilizable collateral to total debt plus the supplied prospective borrow); returns the max value when there is no debt.
    /// @param _positionId The position ID
    /// @param _currentBorrowValue An additional prospective borrow value in USD to include in the debt
    /// @return The health factor scaled by 1e18
    function getHealthFactor(uint256 _positionId, uint256 _currentBorrowValue) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getHealthFactor(_positionId, _currentBorrowValue);
    }

    /// @notice Return a position's current open-ended debt for a token in token units, including accrued interest.
    /// @param _positionId The position ID
    /// @param _token The borrowed token
    /// @return The outstanding debt for the token, including interest
    function getBorrowDetails(uint256 _positionId, address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._calculateUserDebt(_positionId, _token, 0);
    }

    /// @notice Return the configured loan-to-value ratio for a collateral token.
    /// @param _token The collateral token
    /// @return The token's LTV in basis points
    function getCollateralTokenLTV(address _token) external view returns (uint16) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_collateralTokenLTV[_token];
    }

    /// @notice Return the protocol's current interest rate and penalty rate.
    /// @return The annual interest rate in basis points
    /// @return The penalty rate in basis points
    function getInterestRate() external view returns (uint16, uint16) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return (s.s_interestRate, s.s_penaltyRate);
    }

    /// @notice Get the total debt for active tenured loans for a position
    /// @dev This function calculates the total outstanding debt for all active loans associated with a given position ID.
    /// It iterates through each active loan, computes the outstanding balance using the `_outstandingBalance` function from the `LibProtocol` library,
    /// and sums them up to return the total debt.
    /// @param _positionId The ID of the position for which to calculate the total active debt
    /// @return uint256 The total outstanding debt for all active loans of the position
    function getTotalActiveDebt(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._totalActiveDebt(_positionId);
    }

    /// @notice Return the outstanding balance of a fixed-term loan at the current block timestamp, including interest and any post-maturity penalty.
    /// @param _loanId The loan ID
    /// @return The loan's outstanding balance in token units
    function getOutstandingDebtForLoan(uint256 _loanId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._outstandingBalance(_loanId, block.timestamp);
    }

    /// @notice Return the list of active fixed-term loan IDs for a position.
    /// @param _positionId The position ID
    /// @return The array of active loan IDs for the position
    function getUserActiveLoanIds(uint256 _positionId) external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getUserActiveLoanIds(_positionId);
    }

    /// @notice Return the IDs of every fulfilled (active) fixed-term loan across all positions, scanning all loans ever created.
    /// @return The array of all active loan IDs
    function getActiveLoanIds() external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getActiveLoanIds();
    }

    /// @notice Return the full details of a fixed-term loan, including its current outstanding debt at the present timestamp.
    /// @param _loanId The loan ID
    /// @return positionId The position that owns the loan
    /// @return token The borrowed token
    /// @return principal The loan's remaining principal (falls back to the recorded original principal when zero)
    /// @return repaid The cumulative amount repaid against the loan
    /// @return tenureSeconds The loan's tenure in seconds
    /// @return startTimestamp The loan's origination timestamp
    /// @return debt The loan's current outstanding balance including interest and penalty
    /// @return annualRateBps The loan's annual interest rate in basis points
    /// @return penaltyRateBps The loan's penalty rate in basis points
    /// @return status The loan's status as a uint8 enum value
    function getLoanDetails(uint256 _loanId)
        external
        view
        returns (
            uint256 positionId,
            address token,
            uint256 principal,
            uint256 repaid,
            uint256 tenureSeconds,
            uint256 startTimestamp,
            uint256 debt,
            uint16 annualRateBps,
            uint16 penaltyRateBps,
            uint8 status
        )
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getLoanDetails(_loanId);
    }

    // VaultManager functions
    /// @notice Return the total assets held by a token's vault; reverts if no vault exists for the asset.
    /// @param asset The token whose vault to query
    /// @return The vault's total assets
    function getVaultTotalAssets(address asset) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getVaultTotalAssets(asset);
    }

    /// @notice Return whether a token is currently supported for deposit and borrowing.
    /// @param _token The token to check
    /// @return True if the token is supported
    function tokenIsSupported(address _token) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._tokenIsSupported(_token);
    }

    /// @notice Return the vault contract address for a token (zero address if none deployed).
    /// @param _token The token to look up
    /// @return The token's vault address
    function getTokenVault(address _token) external view returns (address) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getTokenVault(_token);
    }
}

```

### contracts/facets/LiquidationFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibLiquidation} from "../libraries/LibLiquidation.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title LiquidationFacet — liquidation of under-collateralized positions and fixed-term loans
contract LiquidationFacet is SecurityBase {
    using LibLiquidation for LibAppStorage.StorageLayout;

    /// @notice Return whether a position is eligible for liquidation, i.e. its debt exceeds the liquidation threshold applied to its collateral value.
    /// @param _positionId The position ID
    /// @return True if the position can be liquidated
    function isLiquidatable(uint256 _positionId) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._isLiquidatable(_positionId);
    }

    /// @notice Liquidate a fixed-term loan: the caller repays up to the loan's debt and seizes the equivalent collateral plus the liquidation bonus, requiring the owning position to be liquidatable.
    /// @param _loanId The loan to liquidate
    /// @param _amount The repayment amount (clamped to the loan's outstanding debt)
    /// @param _collateralToken The collateral token to seize from the position
    function liquidateLoan(uint256 _loanId, uint256 _amount, address _collateralToken) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._liquidateLoan(_loanId, _amount, _collateralToken);
    }

    /// @notice Liquidate a position's open-ended borrow for a token: the caller repays the borrow and seizes the equivalent collateral plus the liquidation bonus, requiring the position to be liquidatable and to have an active borrow for the token.
    /// @param _positionId The position to liquidate
    /// @param _amount The repayment amount
    /// @param _token The borrowed token being repaid
    /// @param _collateralToken The collateral token to seize from the position
    function liquidatePosition(uint256 _positionId, uint256 _amount, address _token, address _collateralToken)
        external
        nonReentrant
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._liquidatePosition(_positionId, _amount, _token, _collateralToken);
    }
}

```

### contracts/facets/OwnershipFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IERC173} from "../interfaces/IERC173.sol";

/// @title OwnershipFacet — ERC-173 ownership management for the diamond
contract OwnershipFacet is IERC173 {
    /// @notice Transfers diamond ownership to a new address; callable only by the current owner.
    /// @param _newOwner The address to set as the new contract owner.
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    /// @notice Returns the current owner of the diamond.
    /// @return owner_ The address of the current contract owner.
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }
}

```

### contracts/facets/PositionManagerFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPositionManager} from "../libraries/LibPositionManager.sol";

import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title PositionManagerFacet — position creation, ownership transfer, and whitelist administration
contract PositionManagerFacet is SecurityBase {
    using LibPositionManager for LibAppStorage.StorageLayout;

    /// @notice Create a new position for a whitelisted user; reverts if the user already owns a position.
    /// @param _user The address to create a position for
    /// @return The newly created position ID
    function createPositionFor(address _user) external returns (uint256) {
        return LibPositionManager._createPositionFor(LibAppStorage.appStorage(), _user);
    }

    /// @notice Transfer the caller's position to a new address, clearing the caller's ownership and whitelist entry; both addresses must be whitelisted and the new address must not already own a position.
    /// @param _newAddress The address to receive the caller's position
    /// @return _positionId The transferred position ID
    function transferPositionOwnership(address _newAddress) external returns (uint256 _positionId) {
        _positionId = LibPositionManager._transferPositionId(LibAppStorage.appStorage(), msg.sender, _newAddress);
    }

    /// @notice Force-transfer a position from its current owner to a new address (only security council), resolving the current owner from the position ID.
    /// @param _positionId The position to transfer
    /// @param _newAddress The address to receive the position
    /// @return The transferred position ID
    function adminForceTransferPositionOwnership(uint256 _positionId, address _newAddress)
        external
        onlySecurityCouncil
        returns (uint256)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        address _user = s._getUserForPositionId(_positionId);
        _positionId = s._transferPositionId(_user, _newAddress);
        return _positionId;
    }

    /// @notice Add an address to the whitelist, permitting it to create positions and interact with the protocol (only security council).
    /// @param _user The address to whitelist
    function whitelistAddress(address _user) external onlySecurityCouncil {
        LibPositionManager._whitelistAddress(LibAppStorage.appStorage(), _user);
    }

    /// @notice Remove an address from the whitelist (only security council).
    /// @param _user The address to blacklist
    function blacklistAddress(address _user) external onlySecurityCouncil {
        LibPositionManager._blacklistAddress(LibAppStorage.appStorage(), _user);
    }

    /// @notice Set the trusted signer whose signature authorizes cross-chain borrow requests (only security council).
    /// @param _signer The new request-borrow signer address
    function setRequestBorrowSigner(address _signer) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s.s_requestBorrowSigner = _signer;
    }

    // Getter functions

    /// @notice Return the position ID that the next created position will receive.
    /// @return The next position ID
    function getNextPositionId() external view returns (uint256) {
        return LibPositionManager._getNextPositionId(LibAppStorage.appStorage());
    }

    /// @notice Return the position ID owned by a given user, or zero if none.
    /// @param _user The user address to look up
    /// @return The user's position ID (zero if the user owns no position)
    function getPositionIdForUser(address _user) external view returns (uint256) {
        return LibPositionManager._getPositionIdForUser(LibAppStorage.appStorage(), _user);
    }

    /// @notice Return the owner address of a given position ID.
    /// @param _positionId The position ID to look up
    /// @return The position owner's address
    function getUserForPositionId(uint256 _positionId) external view returns (address) {
        return LibPositionManager._getUserForPositionId(LibAppStorage.appStorage(), _positionId);
    }

    /// @notice Return the currently configured cross-chain borrow-request signer.
    /// @return The request-borrow signer address
    function getRequestBorrowSigner() external view returns (address) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_requestBorrowSigner;
    }
}

```

### contracts/facets/PriceOracleFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPriceOracle} from "../libraries/LibPriceOracle.sol";
import {ADDRESS_NOT_WHITELISTED} from "../models/Error.sol";

/// @title PriceOracleFacet — Chainlink price-feed reads and Chainlink Functions oracle administration
contract PriceOracleFacet {
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using FunctionsRequest for FunctionsRequest.Request;

    /// @notice Reads the latest Chainlink price for a token, reverting if the token is unsupported,
    ///         the answer is non-positive, or the round is stale.
    /// @param _token The token whose price feed is queried.
    /// @return Whether the returned price is considered stale (always false on success).
    /// @return The latest price answer in the feed's native decimals.
    function getPriceData(address _token) external view returns (bool, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPriceData(_token);
    }

    /// @notice Computes the USD value of a token amount, normalized to 18-decimal precision.
    /// @param _token The token to value.
    /// @param _amount The token amount to convert.
    /// @return The latest price answer used in the conversion.
    /// @return The USD-equivalent value scaled to 18 decimals.
    function getTokenValueInUSD(address _token, uint256 _amount) external view returns (uint256, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getTokenValueInUSD(_token, _amount);
    }

    /// @notice Sets a per-token staleness threshold for its price feed; owner only.
    /// @param _token The token whose feed staleness threshold is updated.
    /// @param _threshold The maximum age in seconds before the feed is treated as stale (0 reverts to the default).
    function setPriceFeedStalenessThreshold(address _token, uint32 _threshold) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setPriceFeedStalenessThreshold(_token, _threshold);
    }

    /// @notice Initializes the Chainlink Functions oracle by setting the gas limit and configuring the router; owner only.
    /// @param _donID The Decentralized Oracle Network (DON) identifier.
    /// @param _router The Chainlink Functions router address.
    /// @param _linkToken The LINK token address used to pay for requests.
    /// @param _gasLimit The callback gas limit for fulfillment.
    /// @param _subscriptionId The Chainlink Functions subscription id to charge.
    function initializePriceOracle(
        bytes32 _donID,
        address _router,
        address _linkToken,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._initializePriceOracle(_donID, _router, _linkToken, _gasLimit, _subscriptionId);
    }

    /**
     * @notice setup the Chainlink router address and sets the DON ID
     * @param _donID The ID of the Decentralized Oracle Network (DON)
     * @param _router The address of the Chainlink Functions router contract
     * @param _linkToken The address of the LINK token used to pay for requests
     * @param _subscriptionId The Chainlink Functions subscription id to charge
     */
    function setupRouter(bytes32 _donID, address _router, address _linkToken, uint64 _subscriptionId) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setupRouter(_donID, _router, _linkToken, _subscriptionId);
    }

    /// @notice Stores the inline JavaScript source executed by the Chainlink Functions request; owner only.
    /// @param _source The JavaScript source code run by the DON when fulfilling price requests.
    function setupSource(string calldata _source) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setupSource(_source);
    }

    /**
     * @notice Sends an HTTP request for character information
     * @param subscriptionId The ID for the Chainlink subscription
     * @param args The arguments to pass to the HTTP request
     * @return requestId The ID of the request
     */
    function sendRequest(uint64 subscriptionId, string[] calldata args) external returns (bytes32 requestId) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        // Refresh is keeper-triggered: only whitelisted keepers may bill the
        // protocol's LINK subscription, and the caller-supplied id is ignored in
        // favour of the protocol's own subscription so it can never be redirected.
        if (!s.isWhitelisted[msg.sender]) revert ADDRESS_NOT_WHITELISTED(msg.sender);
        subscriptionId = s.s_subscriptionId;

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s.s_source); // Initialize the request with JS code
        if (args.length > 0) req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        bytes32 s_lastRequestId = s._sendRequest(req.encodeCBOR(), subscriptionId, s.s_gasLimit, s.s_donID);

        return s_lastRequestId;
    }

    /**
     * @notice Callback function for fulfilling a request
     * @param _requestId The ID of the request to fulfill
     * @param _response The HTTP response data
     * @param _err Any errors from the Functions request
     */
    function handleOracleFulfillment(bytes32 _requestId, bytes memory _response, bytes memory _err) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._handleOracleFulfillment(_requestId, _response, _err);
    }

    /// @notice Approves and funds the protocol's Chainlink Functions subscription with LINK; owner only.
    /// @param _amount The amount of LINK to transfer into the subscription.
    function fundSubscription(uint96 _amount) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._fundSubscription(_amount);
    }

    /// @notice Sets the Chainlink Functions subscription id charged for requests; owner only.
    /// @param _subId The subscription id to store.
    function setSubscriptionId(uint64 _subId) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setSubscriptionId(_subId);
    }

    // Getter functions

    /// @notice Returns the currently configured Chainlink Functions subscription id.
    /// @return The stored subscription id.
    function getSubscriptionId() external view returns (uint64) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_subscriptionId;
    }

    /// @notice Returns the configured Chainlink Functions router address and DON id.
    /// @return The Chainlink Functions router address.
    /// @return The Decentralized Oracle Network (DON) identifier.
    function getRouterInfo() external view returns (address, bytes32) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return (s.s_router, s.s_donID);
    }

    /// @notice Returns the inline JavaScript source executed by Chainlink Functions requests.
    /// @return The stored JavaScript source code.
    function getSource() external view returns (string memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_source;
    }
}

```

### contracts/facets/ProtocolFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";

import "../models/Error.sol";
import {BorrowRequest} from "../models/Protocol.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title ProtocolFacet — borrowing, repayment, and collateral entry points for the lending diamond
contract ProtocolFacet is SecurityBase {
    using LibProtocol for LibAppStorage.StorageLayout;

    /**
     * @notice Deposit collateral tokens to a position
     * @param _token The collateral token address
     * @param _amount The amount to deposit
     */
    function depositCollateral(address _token, uint256 _amount) external payable nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._depositCollateral(_token, _amount);
    }

    /**
     * @notice Withdraw collateral tokens from a position
     * @param _token The collateral token address
     * @param _amount The amount to withdraw
     */
    function withdrawCollateral(address _token, uint256 _amount) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._withdrawCollateral(_token, _amount);
    }

    /// @notice Borrow a supported token against the caller's position, accruing interest at the fixed protocol rate; reverts if the resulting health factor is below the minimum or the vault is over-utilized.
    /// @param _token The token to borrow
    /// @param _amount The amount to borrow
    /// @return The caller's total outstanding debt for the token after borrowing
    function borrow(address _token, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._borrow(_token, _amount);
    }

    /// @notice Repay the caller's open-ended borrow for a token, applying the payment to debt and the principal portion to the vault; the amount is clamped to the outstanding debt.
    /// @param _token The borrowed token to repay
    /// @param _amount The amount to repay (clamped to the outstanding debt)
    /// @return The caller's remaining debt for the token after repayment
    function repay(address _token, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repay(_token, _amount);
    }

    /// @notice Open a fixed-term loan against the caller's position for a supported token; reverts if the tenure is below one day, the vault is over-utilized, or the health factor would drop below the minimum.
    /// @param _token The token to borrow
    /// @param _principal The loan principal
    /// @param _tenureSeconds The loan duration in seconds (minimum one day)
    /// @return The newly created loan ID
    function takeLoan(address _token, uint256 _principal, uint256 _tenureSeconds)
        external
        nonReentrant
        returns (uint256)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._takeLoan(_token, _principal, _tenureSeconds);
    }

    /// @notice Open a fixed-term loan on behalf of a wallet from a signed cross-chain borrow request, validating the signer, target chain, contract, deadline, and a single-use nonce before fulfilling.
    /// @param params The borrow request describing wallet, position, token, amount, tenure, chain IDs, nonce, and deadline
    /// @param signature The protocol signer's signature over the request
    /// @return The newly created loan ID
    function requestBorrow(BorrowRequest calldata params, bytes calldata signature)
        external
        nonReentrant
        returns (uint256)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._requestBorrow(params, signature);
    }

    /// @notice Repay a fixed-term loan owned by a given position, allocating interest and penalty before principal; the payment is clamped to the outstanding debt and must at least cover accrued interest.
    /// @param positionId The position that owns the loan
    /// @param loanId The loan to repay
    /// @param _amount The amount to repay (clamped to the outstanding debt)
    /// @return The loan's remaining principal after repayment
    function repayLoanFor(uint256 positionId, uint256 loanId, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repayLoanFor(positionId, loanId, _amount);
    }

    /// @notice Repay one of the caller's own fixed-term loans, resolving the caller's position before applying the interest-first repayment.
    /// @param loanId The loan to repay
    /// @param _amount The amount to repay (clamped to the outstanding debt)
    /// @return The loan's remaining principal after repayment
    function repayLoan(uint256 loanId, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repayLoan(loanId, _amount);
    }

    /**
     * @notice Add a token as accepted collateral (only security council)
     * @param _token The token address to add as collateral
     */
    function addCollateralToken(address _token, address _pricefeed, uint16 _tokenLTV) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._addCollateralToken(_token, _pricefeed, _tokenLTV);
    }

    /**
     * @notice Remove a token from accepted collateral (only security council)
     * @param _token The token address to remove from collateral
     */
    function removeCollateralToken(address _token) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._removeCollateralToken(_token);
    }

    /// @notice Set the protocol's borrow interest rate and penalty rate, propagating the new interest rate to every deployed vault (only security council).
    /// @param _newInterestRate The new annual interest rate in basis points (non-zero)
    /// @param _newPenaltyRate The new penalty rate in basis points (non-zero)
    function setInterestRate(uint16 _newInterestRate, uint16 _newPenaltyRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setInterestRate(_newInterestRate, _newPenaltyRate);
    }

    /// @notice Update the loan-to-value ratio for an already-supported collateral token (only security council); reverts if the new LTV is below 10%.
    /// @param _token The collateral token to update
    /// @param _tokenNewLTV The new LTV in basis points (minimum 1000)
    function setCollateralTokenLtv(address _token, uint16 _tokenNewLTV) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setCollateralTokenLtv(_token, _tokenNewLTV);
    }
}

```

### contracts/facets/VaultManagerFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibVaultManager} from "../libraries/LibVaultManager.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";

import {VaultConfiguration} from "../models/Protocol.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title VaultManagerFacet — LP deposit/withdraw and security-council vault administration
contract VaultManagerFacet is SecurityBase {
    using LibVaultManager for LibAppStorage.StorageLayout;

    /// @notice Deposit a supported token into its vault on behalf of the caller, crediting the amount actually received and minting vault shares; creates a position for the caller if none exists.
    /// @param _token The token to deposit
    /// @param _amount The amount to transfer in (vault is credited the balance actually received)
    /// @return The number of vault shares minted to the caller
    function deposit(address _token, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._deposit(msg.sender, _token, _amount);
    }

    /// @notice Withdraw a token amount from its vault for the caller, burning the corresponding shares and decrementing the deposit base by the principal portion only.
    /// @param _token The token to withdraw
    /// @param _amount The asset amount to withdraw
    function withdraw(address _token, uint256 _amount) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._withdraw(msg.sender, _token, _amount);
    }

    /// @notice Deploy a new ERC4626 vault for a token, registering it as supported with its price feed and configuration (only security council); reverts if a vault already exists for the token.
    /// @param _token The underlying token for the new vault
    /// @param _pricefeed The price feed address for the token
    /// @param _name The vault share token name
    /// @param _symbol The vault share token symbol
    /// @param _config The vault configuration (reserve factor, rates, optimal utilization, liquidation bonus)
    /// @return The address of the newly deployed vault
    function deployVault(
        address _token,
        address _pricefeed,
        string calldata _name,
        string calldata _symbol,
        VaultConfiguration calldata _config
    ) external nonReentrant onlySecurityCouncil returns (address) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._deployVault(_token, _pricefeed, _name, _symbol, _config);
    }

    /// @notice Replace a token's vault contract with a freshly deployed one carrying the given config (only security council); reverts unless the existing vault is empty (no outstanding shares or borrows).
    /// @param _token The token whose vault is being replaced
    /// @param _config The configuration for the new vault
    /// @return The address of the newly deployed vault
    function upgradeVault(address _token, VaultConfiguration memory _config)
        external
        nonReentrant
        onlySecurityCouncil
        returns (address)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._upgradeVault(_token, _config);
    }

    // ====== Security Council Vault Config Setters ======
    /// @notice Set a token vault's reserve factor in both the stored config and the vault contract (only security council); reverts on a zero value.
    /// @param _token The token whose vault to configure
    /// @param _reserveFactor The new reserve factor in basis points (non-zero)
    function setReserveFactor(address _token, uint16 _reserveFactor) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibVaultManager._setReserveFactor(s, _token, _reserveFactor);
    }

    /// @notice Set a token vault's interest-rate-model base rate (only security council); reverts on zero or if the base rate exceeds the slope rate.
    /// @param _token The token whose vault config to update
    /// @param _baseRate The new base rate in basis points (non-zero, not above the slope rate)
    function setBaseRate(address _token, uint16 _baseRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibVaultManager._setBaseRate(s, _token, _baseRate);
    }

    /// @notice Set a token vault's interest-rate-model slope rate (only security council); reverts on zero or if the slope rate is below the base rate.
    /// @param _token The token whose vault config to update
    /// @param _slopeRate The new slope rate in basis points (non-zero, not below the base rate)
    function setSlopeRate(address _token, uint16 _slopeRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibVaultManager._setSlopeRate(s, _token, _slopeRate);
    }

    /// @notice Set a token vault's optimal utilization point for the interest-rate model (only security council); reverts on zero or a value below 50%.
    /// @param _token The token whose vault config to update
    /// @param _optimalUtilization The new optimal utilization in basis points (minimum 5000)
    function setOptimalUtilization(address _token, uint16 _optimalUtilization) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibVaultManager._setOptimalUtilization(s, _token, _optimalUtilization);
    }

    /// @notice Set a token vault's liquidation bonus applied to liquidators (only security council); reverts if the bonus exceeds 10%.
    /// @param _token The token whose vault config to update
    /// @param _liquidationBonus The new liquidation bonus in basis points (maximum 1000)
    function setLiquidationBonus(address _token, uint16 _liquidationBonus) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibVaultManager._setLiquidationBonus(s, _token, _liquidationBonus);
    }

    /// @notice Mark a token as unsupported so it can no longer be deposited or borrowed (only security council); reverts if the token is not currently supported.
    /// @param _token The token to pause support for
    function pauseTokenSupport(address _token) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._pauseTokenSupport(_token);
    }

    /// @notice Re-mark a token with a deployed vault as supported (only security council); reverts if no vault exists and no-ops if it is already supported.
    /// @param _token The token to resume support for
    function resumeTokenSupport(address _token) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._resumeTokenSupport(_token);
    }

    /// @notice Return the stored vault configuration for a token.
    /// @param _token The token whose vault config to read
    /// @return The token's vault configuration struct
    function getTokenVaultConfig(address _token) external view returns (VaultConfiguration memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_tokenVaultConfig[_token];
    }

    /// @notice Return a token vault's total assets and total outstanding borrows, read live from the vault contract.
    /// @param _token The token whose vault to query
    /// @return The vault's total assets
    /// @return The vault's total outstanding borrows
    function getTokenVaultDetails(address _token) external view returns (uint256, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        // VaultConfiguration memory _config = s.s_tokenVaultConfig[_token];
        // return (_config.totalDeposits, _config.totalBorrows);
        return s._getTokenVaultDetails(_token);
    }

    /// @notice Claim the protocol's accrued interest reserve for a token's vault.
    /// @param _token The vault's underlying token
    /// @param _to Recipient (defaults to the security council if zero)
    /// @param _amount Amount to claim (clamped to the available reserve)
    /// @return harvested The amount actually transferred
    function harvestVaultReserve(address _token, address _to, uint256 _amount)
        external
        onlySecurityCouncil
        returns (uint256 harvested)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        address _recipient = _to == address(0) ? LibDiamond.contractOwner() : _to;
        return s._harvestVaultReserve(_token, _recipient, _amount);
    }

    /// @notice The protocol's currently-claimable interest reserve for a token.
    function getVaultReserve(address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getVaultReserve(_token);
    }

    /// @notice Write off unrecoverable principal on a token's vault, socializing
    ///         the loss across LPs (security council only).
    function writeOffBadDebt(address _token, uint256 _amount) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._writeOffBadDebt(_token, _amount);
    }

    /// @notice Emergency-pause or resume a token vault's deposits (council only).
    function setVaultPaused(address _token, bool _paused) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setVaultPaused(_token, _paused);
    }
}

```

### contracts/facets/YieldStrategyFacet.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPositionManager} from "../libraries/LibPositionManager.sol";
import {LibYieldStrategy} from "../libraries/LibYieldStrategy.sol";

import {YieldStrategyConfig, YieldPosition} from "../models/Yield.sol";
import "../models/Error.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title YieldStrategyFacet — Aave-backed yield strategy configuration and yield claiming for collateral
contract YieldStrategyFacet is SecurityBase {
    using LibPositionManager for LibAppStorage.StorageLayout;

    /// @notice Enable and configure an Aave yield strategy for a token (only security council), validating that the aToken matches the pool's reserve aToken; rejects the native token.
    /// @param _token The collateral token to configure yield for
    /// @param _aavePool The Aave pool used to supply and withdraw the token
    /// @param _aToken The Aave aToken expected for the token in that pool
    /// @param _allocationBps The fraction of collateral allocated to the strategy, in basis points
    /// @param _protocolShareBps The protocol's share of accrued yield, in basis points
    function configureYieldToken(
        address _token,
        address _aavePool,
        address _aToken,
        uint16 _allocationBps,
        uint16 _protocolShareBps
    ) external onlySecurityCouncil {
        LibYieldStrategy._configureYieldToken(
            LibAppStorage.appStorage(), _token, _aavePool, _aToken, _allocationBps, _protocolShareBps
        );
    }

    /// @notice Pause or resume an enabled token's yield strategy (only security council); reverts if yield is not enabled for the token.
    /// @param _token The token whose strategy to pause or resume
    /// @param _paused True to pause, false to resume
    function setYieldPause(address _token, bool _paused) external onlySecurityCouncil {
        LibYieldStrategy._setYieldPause(LibAppStorage.appStorage(), _token, _paused);
    }

    /// @notice Rebalance the caller's yield position for a token, accruing yield and moving collateral to or from Aave to hit the configured allocation target; reverts if the caller has no position.
    /// @param _token The token to rebalance
    function rebalanceMyPosition(address _token) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        LibYieldStrategy._rebalancePosition(s, _positionId, _token);
    }

    /// @notice Claim the caller's accrued user yield for a token, withdrawing it from Aave and transferring it to the recipient (defaults to the caller when zero); reverts if the caller has no position or nothing to claim.
    /// @param _token The token to claim yield for
    /// @param _amount The amount to claim (zero or above the available amount claims the full available balance)
    /// @param _recipient The address to receive the claimed yield (defaults to the caller if zero)
    /// @return claimed The amount of yield actually claimed
    function claimYield(address _token, uint256 _amount, address _recipient)
        external
        nonReentrant
        returns (uint256 claimed)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        address _to = _recipient == address(0) ? msg.sender : _recipient;
        claimed = LibYieldStrategy._claimYield(s, _positionId, _token, _to, _amount);
        return claimed;
    }

    /// @notice Harvest the protocol's accrued yield share for a token, withdrawing it from Aave and transferring it to the recipient (defaults to the diamond owner when zero) (only security council).
    /// @param _token The token to harvest protocol yield for
    /// @param _recipient The address to receive the harvested yield (defaults to the contract owner if zero)
    /// @param _amount The amount to harvest (zero or above the available amount harvests the full available balance)
    /// @return harvested The amount of protocol yield actually harvested
    function harvestProtocolYield(address _token, address _recipient, uint256 _amount)
        external
        nonReentrant
        onlySecurityCouncil
        returns (uint256 harvested)
    {
        address _to = _recipient == address(0) ? LibDiamond.contractOwner() : _recipient;
        harvested = LibYieldStrategy._harvestProtocolYield(LibAppStorage.appStorage(), _token, _to, _amount);
        return harvested;
    }

    /// @notice Return the stored yield strategy configuration for a token.
    /// @param _token The token whose yield config to read
    /// @return The token's yield strategy configuration struct
    function getYieldConfig(address _token) external view returns (YieldStrategyConfig memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_yieldConfigs[_token];
    }

    /// @notice Return a user's yield position for a token, or a zeroed position if the user owns no position.
    /// @param _user The user whose yield position to read
    /// @param _token The token whose yield position to read
    /// @return The user's yield position struct for the token
    function getYieldPosition(address _user, address _token) external view returns (YieldPosition memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(_user);
        if (_positionId == 0) {
            return YieldPosition({principal: 0, userAccrued: 0, entryAccYieldPerPrincipalRay: 0});
        }
        return s.s_positionYield[_positionId][_token];
    }

    /// @notice Return the caller's currently claimable yield for a token, including yield accrued but not yet settled; returns zero if the caller has no position.
    /// @param _token The token to query pending yield for
    /// @return The caller's pending claimable yield
    function getPendingYield(address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) {
            return 0;
        }
        return LibYieldStrategy._pendingYield(s, _positionId, _token);
    }
}

```

### contracts/libraries/LibAppStorage.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFunctionsRouter} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsRouter.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import {TokenVault} from "../TokenVault.sol";

import "../models/Protocol.sol";
import "../models/Yield.sol";

/// @title LibAppStorage — Diamond shared-storage layout and accessor for the lending protocol
library LibAppStorage {
    struct StorageLayout {
        IFunctionsRouter i_router;
        LinkTokenInterface i_linkToken;
        uint256 s_nextPositionId;
        uint256 s_nextLoanId;
        uint16 s_interestRate;
        uint16 s_penaltyRate;
        mapping(uint256 => address) s_positionOwner; // PositionID -> Owner Address
        mapping(address => uint256) s_ownerPosition; // Owner Address -> PositionID
        mapping(bytes32 => uint256) s_requestIdToBorrowId; // Chainlink RequestID -> BorrowID

        // borrowable token related storage
        address[] s_allSupportedTokens;
        mapping(address => bool) s_supportedToken;
        mapping(string => address) s_localCurrencyToToken; // currency string -> token address
        mapping(address => address) s_tokenPriceFeed; // token address -> price feed address
        mapping(address => TokenVault) i_tokenVault;
        mapping(address => VaultConfiguration) s_tokenVaultConfig; // token address -> vault config

        // collateral tracking
        mapping(uint256 => mapping(address => uint256)) s_positionCollateral; // PositionID -> (Token Address -> Amount)
        mapping(address => bool) s_supportedCollateralTokens;
        mapping(address => uint16) s_collateralTokenLTV;
        address[] s_allCollateralTokens; // list of all collateral tokens

        // borrow tracking
        mapping(uint256 => mapping(address => uint256)) s_positionBorrowed; // PositionID -> (token address -> Amount)
        mapping(uint256 => mapping(address => uint256)) s_positionBorrowedLastUpdate; // PositionID -> (token address -> timestamp)

        // tenured loans tracking
        mapping(uint256 => Loan) s_loans; // loanId -> Loan struct
        mapping(uint256 => uint256[]) s_positionActiveLoanIds; // positionId -> list of loanIds
        mapping(uint256 => uint256[]) s_positionClosedLoanIds; // positionId -> list of closed loanIds

        // yield strategy state
        mapping(address => YieldStrategyConfig) s_yieldConfigs; // collateral token -> yield config
        mapping(uint256 => mapping(address => YieldPosition)) s_positionYield; // positionId -> (token -> yield position)
        mapping(address => bool) s_yieldApprovals; // collateral token -> approval flag for Aave pool

        mapping(address => bool) isWhitelisted; // address -> whitelist status

        address s_requestBorrowSigner;
        mapping(address => mapping(uint256 => bool)) s_requestBorrowNonceUsed;

        // Chainlink functions variables
        uint32 s_gasLimit;
        uint64 s_subscriptionId;
        bytes32 s_donID;
        bytes32 s_lastRequestId;
        bytes s_lastResponse;
        bytes s_lastError;
        string s_source;
        address s_router;
        mapping(bytes32 _requestId => FunctionResponse) s_functionResponse;
        mapping(uint256 => uint256) s_loanPrincipal;
        mapping(uint256 => uint256) s_loanStartTime;
        mapping(address => uint32) s_priceFeedStalenessThreshold; // token address -> max age in seconds (0 = use default)
        uint256 s_reentrancyStatus; // 1 = not entered, 2 = entered (0 defaults to 1)
        // Pooled outstanding principal per (position, token). Tracked separately
        // from s_positionBorrowed (which capitalizes interest) so the borrow
        // tally is decremented by principal only on repay. Appended at the end of
        // the struct for upgrade-safe storage layout.
        mapping(uint256 => mapping(address => uint256)) s_positionPrincipal;
    }

    bytes32 internal constant STORAGE_SLOT = keccak256("contracts.storage.LibAppStorage");

    /// @notice Returns a storage pointer to the protocol's shared `StorageLayout` at a fixed diamond storage slot.
    /// @return ds The storage reference to the protocol's application storage.
    function appStorage() internal pure returns (StorageLayout storage ds) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            ds.slot := slot
        }
    }
}

```

### contracts/libraries/LibDiamond.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

/// @title LibDiamond — EIP-2535 diamond storage, ownership, and facet add/replace/remove logic
library LibDiamond {
    error InValidFacetCutAction();
    error NotDiamondOwner();
    error NoSelectorsInFacet();
    error NoZeroAddress();
    error SelectorExists(bytes4 selector);
    error SameSelectorReplacement(bytes4 selector);
    error MustBeZeroAddress();
    error NoCode();
    error NonExistentSelector(bytes4 selector);
    error ImmutableFunction(bytes4 selector);
    error NonEmptyCalldata();
    error EmptyCalldata();
    error InitCallFailed();
    bytes32 constant DIAMOND_STORAGE_POSITION = keccak256("diamond.standard.diamond.storage");

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition; // position in facetFunctionSelectors.functionSelectors array
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition; // position of facetAddress in facetAddresses array
    }

    struct DiamondStorage {
        // maps function selector to the facet address and
        // the position of the selector in the facetFunctionSelectors.selectors array
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        // maps facet addresses to function selectors
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        // facet addresses
        address[] facetAddresses;
        // Used to query if a contract implements an interface.
        // Used to implement ERC-165.
        mapping(bytes4 => bool) supportedInterfaces;
        // owner of the contract
        address contractOwner;
    }

    /// @notice Returns a storage pointer to the diamond's `DiamondStorage` at the fixed diamond storage slot.
    /// @return ds The storage reference to diamond storage.
    function diamondStorage() internal pure returns (DiamondStorage storage ds) {
        bytes32 position = DIAMOND_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Sets the diamond's contract owner to `_newOwner` and emits OwnershipTransferred.
    /// @param _newOwner The address to set as the new owner; reverts if zero.
    function setContractOwner(address _newOwner) internal {
        if (_newOwner == address(0)) revert NoZeroAddress();
        DiamondStorage storage ds = diamondStorage();
        address previousOwner = ds.contractOwner;
        ds.contractOwner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    /// @notice Returns the current diamond contract owner.
    /// @return contractOwner_ The current owner address.
    function contractOwner() internal view returns (address contractOwner_) {
        contractOwner_ = diamondStorage().contractOwner;
    }

    /// @notice Reverts with NotDiamondOwner unless the caller is the diamond contract owner.
    function enforceIsContractOwner() internal view {
        if (msg.sender != diamondStorage().contractOwner) {
            revert NotDiamondOwner();
        }
    }

    event DiamondCut(IDiamondCut.FacetCut[] _diamondCut, address _init, bytes _calldata);

    // Internal function version of diamondCut
    /// @notice Applies each facet cut (Add/Replace/Remove), emits DiamondCut, then runs the optional initializer.
    /// @param _diamondCut The set of facet cuts to apply.
    /// @param _init The address to delegatecall for initialization, or address(0) for none.
    /// @param _calldata The calldata to delegatecall on `_init`.
    function diamondCut(IDiamondCut.FacetCut[] memory _diamondCut, address _init, bytes memory _calldata) internal {
        for (uint256 facetIndex; facetIndex < _diamondCut.length; facetIndex++) {
            IDiamondCut.FacetCutAction action = _diamondCut[facetIndex].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                addFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                replaceFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Remove) {
                removeFunctions(_diamondCut[facetIndex].facetAddress, _diamondCut[facetIndex].functionSelectors);
            } else {
                revert InValidFacetCutAction();
            }
        }
        emit DiamondCut(_diamondCut, _init, _calldata);
        initializeDiamondCut(_init, _calldata);
    }

    /// @notice Registers `_functionSelectors` to `_facetAddress`, adding the facet if it is new.
    /// @param _facetAddress The facet implementing the selectors; reverts if zero.
    /// @param _functionSelectors The selectors to add; reverts if empty or if any selector already exists.
    function addFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length <= 0) revert NoSelectorsInFacet();
        DiamondStorage storage ds = diamondStorage();
        if (_facetAddress == address(0)) revert NoZeroAddress();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacetAddress != address(0)) revert SelectorExists(selector);
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    /// @notice Re-points `_functionSelectors` to `_facetAddress`, removing each from its previous facet first.
    /// @param _facetAddress The new facet for the selectors; reverts if zero.
    /// @param _functionSelectors The selectors to replace; reverts if empty or if a selector already maps to `_facetAddress`.
    function replaceFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length <= 0) revert NoSelectorsInFacet();
        DiamondStorage storage ds = diamondStorage();
        if (_facetAddress == address(0)) revert NoZeroAddress();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[_facetAddress].functionSelectors.length);
        // add new facet address if it does not exist
        if (selectorPosition == 0) {
            addFacet(ds, _facetAddress);
        }
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacetAddress == _facetAddress) {
                revert SameSelectorReplacement(selector);
            }
            removeFunction(ds, oldFacetAddress, selector);
            addFunction(ds, selector, selectorPosition, _facetAddress);
            selectorPosition++;
        }
    }

    /// @notice Removes `_functionSelectors` from the diamond.
    /// @param _facetAddress Must be address(0) for removals; reverts otherwise.
    /// @param _functionSelectors The selectors to remove; reverts if empty.
    function removeFunctions(address _facetAddress, bytes4[] memory _functionSelectors) internal {
        if (_functionSelectors.length <= 0) revert NoSelectorsInFacet();
        DiamondStorage storage ds = diamondStorage();
        // if function does not exist then do nothing and return
        if (_facetAddress != address(0)) revert MustBeZeroAddress();
        for (uint256 selectorIndex; selectorIndex < _functionSelectors.length; selectorIndex++) {
            bytes4 selector = _functionSelectors[selectorIndex];
            address oldFacetAddress = ds.selectorToFacetAndPosition[selector].facetAddress;
            removeFunction(ds, oldFacetAddress, selector);
        }
    }

    /// @notice Records `_facetAddress` in the facet address list after verifying it has contract code.
    function addFacet(DiamondStorage storage ds, address _facetAddress) internal {
        enforceHasContractCode(_facetAddress);
        ds.facetFunctionSelectors[_facetAddress].facetAddressPosition = ds.facetAddresses.length;
        ds.facetAddresses.push(_facetAddress);
    }

    /// @notice Maps `_selector` to `_facetAddress` and appends it to the facet's selector list at `_selectorPosition`.
    function addFunction(DiamondStorage storage ds, bytes4 _selector, uint96 _selectorPosition, address _facetAddress)
        internal
    {
        ds.selectorToFacetAndPosition[_selector].functionSelectorPosition = _selectorPosition;
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.push(_selector);
        ds.selectorToFacetAndPosition[_selector].facetAddress = _facetAddress;
    }

    /// @notice Removes `_selector` from `_facetAddress` using swap-and-pop, and drops the facet when its last selector is removed.
    /// @dev Reverts on a non-existent selector or on an immutable function defined directly in the diamond.
    function removeFunction(DiamondStorage storage ds, address _facetAddress, bytes4 _selector) internal {
        if (_facetAddress == address(0)) revert NonExistentSelector(_selector);
        // an immutable function is a function defined directly in a diamond
        if (_facetAddress == address(this)) revert ImmutableFunction(_selector);
        // replace selector with last selector, then delete last selector
        uint256 selectorPosition = ds.selectorToFacetAndPosition[_selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[_facetAddress].functionSelectors.length - 1;
        // if not the same then replace _selector with lastSelector
        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[_facetAddress].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[_facetAddress].functionSelectors[selectorPosition] = lastSelector;
            // selectorPosition is an index into a function-selector array; it cannot
            // approach 2^96, so the uint96 cast cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        // delete the last selector
        ds.facetFunctionSelectors[_facetAddress].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[_selector];

        // if no more selectors for facet address then delete the facet address
        if (lastSelectorPosition == 0) {
            // replace facet address with last facet address and delete last facet address
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            uint256 facetAddressPosition = ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacetAddress = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacetAddress;
                ds.facetFunctionSelectors[lastFacetAddress].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[_facetAddress].facetAddressPosition;
        }
    }

    /// @notice Delegatecalls `_calldata` on `_init` to initialize state during a cut, bubbling up any revert.
    /// @param _init The initializer address, or address(0) to skip initialization.
    /// @param _calldata The calldata to execute; must be empty when `_init` is zero and non-empty otherwise.
    function initializeDiamondCut(address _init, bytes memory _calldata) internal {
        if (_init == address(0)) {
            if (_calldata.length > 0) revert NonEmptyCalldata();
        } else {
            if (_calldata.length == 0) revert EmptyCalldata();
            if (_init != address(this)) {
                enforceHasContractCode(_init);
            }
            (bool success, bytes memory error) = _init.delegatecall(_calldata);
            if (!success) {
                if (error.length > 0) {
                    // bubble up the error
                    revert(string(error));
                } else {
                    revert InitCallFailed();
                }
            }
        }
    }

    /// @notice Reverts with NoCode if `_contract` has no deployed bytecode.
    /// @param _contract The address whose code size is checked.
    function enforceHasContractCode(address _contract) internal view {
        uint256 contractSize;
        assembly {
            contractSize := extcodesize(_contract)
        }
        if (contractSize <= 0) revert NoCode();
    }
}

```

### contracts/libraries/LibLiquidation.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibPriceOracle} from "../libraries/LibPriceOracle.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";
import {LibVaultManager} from "../libraries/LibVaultManager.sol";
import {LibUtils} from "../libraries/LibUtils.sol";
import {LibYieldStrategy} from "../libraries/LibYieldStrategy.sol";

import {Constants} from "../models/Constant.sol";
import "../models/Error.sol";
import "../models/Event.sol";
import "../models/Protocol.sol";
import {RepayStateChangeParams} from "../models/FunctionParams.sol";
import {TokenVault} from "../TokenVault.sol";

/// @title LibLiquidation — health checks and liquidation of undercollateralized positions
library LibLiquidation {
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using LibProtocol for LibAppStorage.StorageLayout;
    using SafeERC20 for IERC20;

    /// @notice Determine whether a position is eligible for liquidation.
    /// @dev True when total debt (open + active loans) exceeds the collateral value
    ///      scaled by the liquidation threshold.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to check.
    /// @return True if the position can be liquidated.
    function _isLiquidatable(LibAppStorage.StorageLayout storage s, uint256 _positionId) internal view returns (bool) {
        uint256 _collateral = s._getPositionCollateralValue(_positionId);
        uint256 _debt = s._getPositionBorrowedValue(_positionId) + s._totalActiveDebt(_positionId);
        uint256 _threshold = _collateral * Constants.LIQUIDATION_THRESHOLD / Constants.BASIS_POINTS_SCALE_256;
        // uint256 _healthFactor = s._getHealthFactor(_positionId, 0);
        // return _healthFactor < 1e18;
        return _debt > _threshold;
    }

    /// @notice Liquidate a fixed-term loan, repaying part of its debt and seizing the
    ///         equivalent (bonus-adjusted) collateral for the liquidator.
    /// @dev Clamps `_amount` to outstanding debt, applies interest-first allocation,
    ///      closes the loan when principal hits zero, decrements vault borrows by the
    ///      principal portion, pulls the repayment into the vault, and transfers the
    ///      seized collateral to `msg.sender`.
    /// @param s The diamond storage layout.
    /// @param _loanId The loan being liquidated.
    /// @param _amount The debt amount the liquidator repays (clamped to outstanding).
    /// @param _collateralToken The collateral token seized from the position.
    function _liquidateLoan(
        LibAppStorage.StorageLayout storage s,
        uint256 _loanId,
        uint256 _amount,
        address _collateralToken
    ) internal {
        Loan storage _loan = s.s_loans[_loanId];
        if (_loan.status != LoanStatus.FULFILLED) revert INACTIVE_LOAN();
        _liquidationCheck(s, _loan.positionId, _loan.token, _collateralToken, _amount);

        // Update loan repaid amount
        uint256 _loanDebt = s._outstandingBalance(_loanId, block.timestamp);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        uint256 _amountToLiquidate = _getAmountToLiquidate(s, _collateralToken, _loan.token, _amount);
        if (_amountToLiquidate > s.s_positionCollateral[_loan.positionId][_collateralToken]) {
            revert INSUFFICIENT_COLLATERAL();
        }

        s.s_positionCollateral[_loan.positionId][_collateralToken] -= _amountToLiquidate;
        LibYieldStrategy._rebalanceForWithdrawal(s, _loan.positionId, _collateralToken, _amountToLiquidate);

        uint256 _oldPrincipal = _loan.principal;

        // interest-first allocation, principal reduced by the principal portion
        // only (never fold interest into principal: #12). The pool borrow tally
        // and vault are then decremented by that exact principal.
        uint256 _interestDue = _loanDebt - _oldPrincipal;
        uint256 _principalRepaid = _amount > _interestDue ? _amount - _interestDue : 0;

        // update outstanding loan here
        _loan.repaid += _amount;
        _loan.principal = _oldPrincipal - _principalRepaid;
        _loan.startTimestamp = block.timestamp;

        // If fully repaid, update loan status and move to closed loans
        if (_loan.principal == 0) {
            _loan.status = LoanStatus.LIQUIDATED;
            s._removeLoanFromActive(_loan.positionId, _loanId);
            s.s_positionClosedLoanIds[_loan.positionId].push(_loanId);
        }

        LibVaultManager._updateVaultRepays(s, _loan.token, _principalRepaid);

        TokenVault _tokenVault = s.i_tokenVault[_loan.token];

        IERC20(_loan.token).safeTransferFrom(msg.sender, address(_tokenVault), _amount);
        _tokenVault.repay(_principalRepaid, _amount - _principalRepaid);

        LibProtocol._transferToken(_collateralToken, msg.sender, _amountToLiquidate);

        emit LoanLiquidated(_loan.positionId, _loanId, _collateralToken, msg.sender, _amountToLiquidate);
        emit LoanRepayment(_loan.positionId, _loanId, _loan.token, _amount);
    }

    /// @notice Liquidate a position's open-ended token debt, repaying `_amount` and
    ///         seizing the equivalent (bonus-adjusted) collateral for the liquidator.
    /// @dev Reverts if the position has no borrow for `_token`; applies the
    ///      principal/interest split via `_repayStateChanges`, pulls the repayment
    ///      into the vault, and transfers the seized collateral to `msg.sender`.
    /// @param s The diamond storage layout.
    /// @param _positionId The position being liquidated.
    /// @param _amount The debt amount the liquidator repays.
    /// @param _token The borrowed token being repaid.
    /// @param _collateralToken The collateral token seized from the position.
    function _liquidatePosition(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        uint256 _amount,
        address _token,
        address _collateralToken
    ) internal {
        if (s.s_positionBorrowed[_positionId][_token] == 0) {
            revert NO_ACTIVE_BORROW_FOR_TOKEN(_positionId, _token);
        }
        _liquidationCheck(s, _positionId, _token, _collateralToken, _amount);

        uint256 _amountToLiquidate = _getAmountToLiquidate(s, _collateralToken, _token, _amount);
        if (_amountToLiquidate > s.s_positionCollateral[_positionId][_collateralToken]) {
            revert INSUFFICIENT_COLLATERAL();
        }

        s.s_positionCollateral[_positionId][_collateralToken] -= _amountToLiquidate;
        LibYieldStrategy._rebalanceForWithdrawal(s, _positionId, _collateralToken, _amountToLiquidate);

        RepayStateChangeParams memory _params =
            RepayStateChangeParams({positionId: _positionId, token: _token, amount: _amount});
        uint256 _principalRepaid = s._repayStateChanges(_params);

        TokenVault _tokenVault = s.i_tokenVault[_token];
        IERC20(_token).safeTransferFrom(msg.sender, address(_tokenVault), _amount);
        _tokenVault.repay(_principalRepaid, _amount - _principalRepaid);

        LibProtocol._transferToken(_collateralToken, msg.sender, _amountToLiquidate);

        emit PositionLiquidated(_positionId, msg.sender, _collateralToken, _amountToLiquidate);
        emit Repay(_positionId, _token, _amount);
    }

    /// @notice Validate the preconditions for liquidating a position.
    /// @dev Reverts unless the position is liquidatable, holds the named collateral,
    ///      and the caller has approved/funded the repayment token amount.
    /// @param s The diamond storage layout.
    /// @param _positionId The position being liquidated.
    /// @param _token The repayment token.
    /// @param _collateralToken The collateral token to be seized.
    /// @param _amount The repayment amount to validate allowance/balance for.
    function _liquidationCheck(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        address _token,
        address _collateralToken,
        uint256 _amount
    ) internal view {
        if (!_isLiquidatable(s, _positionId)) revert NOT_LIQUIDATABLE();
        uint256 _collateralAmount = s.s_positionCollateral[_positionId][_collateralToken];
        if (_collateralAmount == 0) revert NO_COLLATERAL_FOR_TOKEN(_positionId, _collateralToken);
        LibProtocol._allowanceAndBalanceCheck(_token, _amount);
    }

    /// @notice Compute the amount of collateral token to seize for a given repayment.
    /// @dev Converts the repaid debt's USD value into collateral units at the
    ///      collateral price, then scales up by the token's liquidation bonus.
    /// @param s The diamond storage layout.
    /// @param _collateralToken The collateral token to seize.
    /// @param _token The repaid (borrowed) token.
    /// @param _amount The repayment amount in `_token` units.
    /// @return The collateral amount to seize, including the liquidation bonus.
    function _getAmountToLiquidate(
        LibAppStorage.StorageLayout storage s,
        address _collateralToken,
        address _token,
        uint256 _amount
    ) internal view returns (uint256) {
        (, uint256 _collateralPricePerToken) = s._getPriceData(_collateralToken);
        if (_collateralPricePerToken == 0) revert ZERO_PRICE_DATA();

        (, uint256 _amountValue) = s._getTokenValueInUSD(_token, _amount);

        uint8 _pricefeedDecimals = s._getPriceDecimals(_collateralToken);

        uint256 _amountToLiquidate = LibUtils._convertUSDToTokenAmount(
            _collateralToken, _amountValue, _collateralPricePerToken, _pricefeedDecimals
        );

        _amountToLiquidate =
            (_amountToLiquidate * (Constants.BASIS_POINTS_SCALE + s.s_tokenVaultConfig[_token].liquidationBonus))
                / Constants.BASIS_POINTS_SCALE;

        return _amountToLiquidate;
    }
}

```

### contracts/libraries/LibPositionManager.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "./LibAppStorage.sol";
import "../models/Error.sol";
import "../models/Event.sol";

/// @title LibPositionManager — Creates, transfers, and looks up user lending positions and their whitelist status
library LibPositionManager {
    /// @notice Creates a new position for a whitelisted `_user` that has no existing position and emits PositionIdCreated.
    /// @param _user The address to create a position for; must be whitelisted and not already own a position.
    /// @return The newly assigned position ID.
    function _createPositionFor(LibAppStorage.StorageLayout storage s, address _user) internal returns (uint256) {
        _addressIsWhitelisted(s, _user);
        if (_userAddressExists(s, _user)) revert ADDRESS_EXISTS(_user);
        uint256 _positionId = s.s_nextPositionId + 1;
        s.s_nextPositionId += 1;

        s.s_positionOwner[_positionId] = _user;
        s.s_ownerPosition[_user] = _positionId;

        emit PositionIdCreated(_positionId, _user);
        return _positionId;
    }

    /// @notice Moves an existing position from `_oldAddress` to `_newAddress`, clearing the old owner's mapping and whitelist, and emits PositionIdTransferred.
    /// @param _oldAddress The current owner; must exist and be whitelisted.
    /// @param _newAddress The new owner; must be whitelisted and not already own a position.
    /// @return _positionId The transferred position ID.
    function _transferPositionId(LibAppStorage.StorageLayout storage s, address _oldAddress, address _newAddress)
        internal
        returns (uint256 _positionId)
    {
        _positionId = _validateUserExists(s, _oldAddress);
        _addressIsWhitelisted(s, _oldAddress);
        _addressIsWhitelisted(s, _newAddress);
        if (_userAddressExists(s, _newAddress)) revert ADDRESS_EXISTS(_newAddress);

        s.s_ownerPosition[_newAddress] = _positionId;
        s.s_positionOwner[_positionId] = _newAddress;

        delete s.s_ownerPosition[_oldAddress];
        delete s.isWhitelisted[_oldAddress];

        emit PositionIdTransferred(_positionId, _oldAddress, _newAddress);
    }

    /// @notice Marks `_user` as whitelisted.
    function _whitelistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.isWhitelisted[_user] = true;
    }

    /// @notice Removes `_user` from the whitelist.
    function _blacklistAddress(LibAppStorage.StorageLayout storage s, address _user) internal {
        s.isWhitelisted[_user] = false;
    }

    /// @notice Returns true if `_user` already owns a position.
    function _userAddressExists(LibAppStorage.StorageLayout storage s, address _user) internal view returns (bool) {
        if (s.s_ownerPosition[_user] == 0) {
            return false;
        }
        return true;
    }

    /// @notice Returns the position ID that would be assigned to the next created position.
    function _getNextPositionId(LibAppStorage.StorageLayout storage s) internal view returns (uint256) {
        return s.s_nextPositionId + 1;
    }

    /// @notice Returns the position ID owned by `_user` (0 if none).
    function _getPositionIdForUser(LibAppStorage.StorageLayout storage s, address _user)
        internal
        view
        returns (uint256)
    {
        return s.s_ownerPosition[_user];
    }

    /// @notice Returns the owner address of `_positionId`.
    function _getUserForPositionId(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (address)
    {
        return s.s_positionOwner[_positionId];
    }

    // Validators
    /// @notice Reverts with NO_POSITION_ID if `_user` owns no position; otherwise returns that position ID.
    /// @return _positionId The position ID owned by `_user`.
    function _validateUserExists(LibAppStorage.StorageLayout storage s, address _user)
        internal
        view
        returns (uint256 _positionId)
    {
        _positionId = _getPositionIdForUser(s, _user);
        if (_positionId == 0) {
            revert NO_POSITION_ID(_user);
        }
    }

    /// @notice Reverts with ADDRESS_NOT_WHITELISTED unless `_user` is whitelisted.
    function _addressIsWhitelisted(LibAppStorage.StorageLayout storage s, address _user) internal view {
        if (!s.isWhitelisted[_user]) {
            revert ADDRESS_NOT_WHITELISTED(_user);
        }
    }
}

```

### contracts/libraries/LibPriceOracle.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFunctionsRouter} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsRouter.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibUtils} from "./LibUtils.sol";

import {
    OnlyRouterCanFulfill,
    UnexpectedRequestID,
    TOKEN_NOT_SUPPORTED,
    STALE_PRICE_FEED,
    INVALID_PRICE_FEED
} from "../models/Error.sol";
import {
    Response,
    RequestSent,
    RequestFulfilled,
    FunctionsRouterChanged,
    FunctionsSourceChanged
} from "../models/Event.sol";
import {FunctionResponse} from "../models/Protocol.sol";

import {Constants} from "../models/Constant.sol";

/// @title The Chainlink Functions client contract converted into a library for the PriceOracleFacet
library LibPriceOracle {
    using FunctionsRequest for FunctionsRequest.Request;

    /// @notice Reads the latest Chainlink price for `_token`, reverting on an unsupported token, non-positive answer, mismatched round, or stale update.
    /// @param _token The token whose configured price feed is read.
    /// @return A staleness flag (always false on success) and the latest price answer in feed decimals.
    function _getPriceData(LibAppStorage.StorageLayout storage s, address _token)
        internal
        view
        returns (bool, uint256)
    {
        address _pricefeed = s.s_tokenPriceFeed[_token];
        if (_pricefeed == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        (uint80 _roundId, int256 _answer,, uint256 _updatedAt, uint80 _answeredInRound) =
            AggregatorV3Interface(_pricefeed).latestRoundData();

        if (_answer <= 0) revert INVALID_PRICE_FEED(_pricefeed);

        if (_roundId != _answeredInRound) revert STALE_PRICE_FEED(_pricefeed);

        uint32 _threshold = s.s_priceFeedStalenessThreshold[_token];
        if (_threshold == 0) _threshold = Constants.DEFAULT_STALENESS_THRESHOLD;
        if (block.timestamp - _updatedAt > _threshold) revert STALE_PRICE_FEED(_pricefeed);

        // `_answer` is guarded `> 0` above, so the int256->uint256 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (false, uint256(_answer));
    }

    /// @notice Sets a custom staleness threshold for a specific token's price feed.
    /// @dev Pass 0 to revert to the protocol-wide DEFAULT_STALENESS_THRESHOLD.
    ///      Typical values: 3600 (1 h) for high-frequency feeds, 86400 (24 h) for low-frequency feeds.
    function _setPriceFeedStalenessThreshold(LibAppStorage.StorageLayout storage s, address _token, uint32 _threshold)
        internal
    {
        s.s_priceFeedStalenessThreshold[_token] = _threshold;
    }

    /// @notice Returns the decimal precision of `_token`'s configured price feed, reverting if the token is unsupported.
    /// @param _token The token whose price feed decimals are queried.
    /// @return The price feed's decimals.
    function _getPriceDecimals(LibAppStorage.StorageLayout storage s, address _token) internal view returns (uint8) {
        address _pricefeed = s.s_tokenPriceFeed[_token];
        if (_pricefeed == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        return AggregatorV3Interface(_pricefeed).decimals();
    }

    /// @notice Computes the USD value of `_amount` of `_token` using its price feed, returning (0, 0) for a zero amount.
    /// @param _token The token to value.
    /// @param _amount The token amount in the token's native decimals.
    /// @return The feed price and the corresponding USD value.
    function _getTokenValueInUSD(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount)
        internal
        view
        returns (uint256, uint256)
    {
        if (_amount == 0) return (0, 0);

        (bool _isStale, uint256 _price) = _getPriceData(s, _token);
        if (_isStale) revert STALE_PRICE_FEED(_token);
        if (_price <= 0) revert INVALID_PRICE_FEED(_token);

        // Normalize to 18 decimals
        uint8 _decimals = LibUtils._getTokenDecimals(_token);
        uint8 _feedDecimals = _getPriceDecimals(s, _token);
        uint256 _usdValue = _calculateTokenUSDEquivalent(_decimals, _feedDecimals, _price, _amount);

        return (_price, _usdValue);
    }

    /// @notice Scales `_price` up to 18 decimals and multiplies by `_amount` to produce the USD value of the token amount.
    /// @param _decimals The token's decimals.
    /// @param _feedDecimals The price feed's decimals.
    /// @param _price The feed price in `_feedDecimals`.
    /// @param _amount The token amount in `_decimals`.
    /// @return _usdValue The USD value (0 when `_amount` is 0).
    function _calculateTokenUSDEquivalent(uint8 _decimals, uint8 _feedDecimals, uint256 _price, uint256 _amount)
        internal
        pure
        returns (uint256 _usdValue)
    {
        if (_amount == 0) return _usdValue;

        // Scale the feed price up from its native decimals to PRECISION_SCALE (18)
        uint256 scaledPrice = _price * (10 ** (Constants.PRECISION_SCALE - _feedDecimals));
        _usdValue = (scaledPrice * _amount) / (10 ** _decimals);
    }

    /// @notice Sets the Chainlink Functions gas limit and wires up the router, LINK token, DON ID, and subscription.
    /// @param _donID The DON identifier.
    /// @param _router The Functions router address.
    /// @param _linkToken The LINK token address.
    /// @param _gasLimit The callback gas limit.
    /// @param _subscriptionId The Functions subscription ID.
    function _initializePriceOracle(
        LibAppStorage.StorageLayout storage s,
        bytes32 _donID,
        address _router,
        address _linkToken,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) internal {
        s.s_gasLimit = _gasLimit;
        _setupRouter(s, _donID, _router, _linkToken, _subscriptionId);
    }

    /// @notice Stores the DON ID, router, LINK token, and subscription ID, then emits FunctionsRouterChanged.
    /// @param _donID The DON identifier.
    /// @param _router The Functions router address.
    /// @param _linkToken The LINK token address.
    /// @param _subscriptionId The Functions subscription ID.
    function _setupRouter(
        LibAppStorage.StorageLayout storage s,
        bytes32 _donID,
        address _router,
        address _linkToken,
        uint64 _subscriptionId
    ) internal {
        s.s_donID = _donID;
        s.s_router = _router;
        s.i_router = IFunctionsRouter(_router);
        s.i_linkToken = LinkTokenInterface(_linkToken);
        s.s_subscriptionId = _subscriptionId;
        emit FunctionsRouterChanged(msg.sender, _donID, _router);
    }

    /// @notice Stores the JavaScript source executed by Chainlink Functions and emits FunctionsSourceChanged.
    /// @param _source The Functions request source code.
    function _setupSource(LibAppStorage.StorageLayout storage s, string calldata _source) internal {
        s.s_source = _source;
        emit FunctionsSourceChanged(msg.sender, abi.encode(_source));
    }

    /// @notice Sends a Chainlink Functions request
    /// @param data The CBOR encoded bytes data for a Functions request
    /// @param subscriptionId The subscription ID that will be charged to service the request
    /// @param callbackGasLimit the amount of gas that will be available for the fulfillment callback
    /// @return requestId The generated request ID for this request
    function _sendRequest(
        LibAppStorage.StorageLayout storage s,
        bytes memory data,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        bytes32 donId
    ) internal returns (bytes32) {
        bytes32 _requestId = s.i_router
            .sendRequest(subscriptionId, data, FunctionsRequest.REQUEST_DATA_VERSION, callbackGasLimit, donId);
        s.s_functionResponse[_requestId] =
            FunctionResponse({requestId: _requestId, responses: "", err: "", priceData: 0, exists: true});
        emit RequestSent(_requestId);
        return _requestId;
    }

    /// @notice User defined function to handle a response from the DON
    /// @param _requestId The request ID, returned by sendRequest()
    /// @param _response Aggregated response from the execution of the user's source code
    /// @param _err Aggregated error from the execution of the user code or from the execution pipeline
    /// @dev Either response or error parameter will be set, but never both
    function _fulfillRequest(
        LibAppStorage.StorageLayout storage s,
        bytes32 _requestId,
        bytes memory _response,
        bytes memory _err
    ) internal {
        FunctionResponse storage res = s.s_functionResponse[_requestId];
        if (!res.exists) {
            revert UnexpectedRequestID(_requestId); // Check if request IDs match
        }
        // Update the contract's state variables with the response and any errors
        res.responses = _response;
        (res.priceData) = abi.decode(_response, (uint256));
        res.err = _err;

        // Emit an event to log the response
        emit Response(_requestId, res.priceData, _response, _err);
    }

    /// @notice Router-gated entry that fulfills `requestId` with the DON response and emits RequestFulfilled.
    /// @param requestId The request ID being fulfilled.
    /// @param response The aggregated DON response.
    /// @param err The aggregated DON error.
    /// @dev Reverts with OnlyRouterCanFulfill unless the caller is the configured Functions router.
    function _handleOracleFulfillment(
        LibAppStorage.StorageLayout storage s,
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal {
        if (msg.sender != address(s.i_router)) {
            revert OnlyRouterCanFulfill();
        }
        _fulfillRequest(s, requestId, response, err);
        emit RequestFulfilled(requestId);
    }

    /// @notice Approves the router for `_amount` of LINK and funds the configured subscription via transferAndCall.
    /// @param _amount The LINK amount to fund the subscription with.
    function _fundSubscription(LibAppStorage.StorageLayout storage s, uint256 _amount) internal {
        // Approve the router to spend the specified amount of LINK
        s.i_linkToken.approve(address(s.i_router), _amount);
        // Fund the subscription
        s.i_linkToken
            .transferAndCall(
                address(s.i_router),
                _amount,
                abi.encode(s.s_subscriptionId) // Encode the subscription ID in the data field
            );
    }

    /// @notice Updates the stored Chainlink Functions subscription ID.
    /// @param _subId The new subscription ID.
    function _setSubscriptionId(LibAppStorage.StorageLayout storage s, uint64 _subId) internal {
        s.s_subscriptionId = _subId;
    }
}

```

### contracts/libraries/LibProtocol.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibPositionManager} from "./LibPositionManager.sol";
import {LibPriceOracle} from "./LibPriceOracle.sol";
import {LibVaultManager} from "./LibVaultManager.sol";
import {LibYieldStrategy} from "./LibYieldStrategy.sol";

import {Constants} from "../models/Constant.sol";
import "../models/Error.sol";
import "../models/Event.sol";
import "../models/Protocol.sol";
import {RepayStateChangeParams} from "../models/FunctionParams.sol";

import {TokenVault} from "../TokenVault.sol";

/// @title LibProtocol — core lending logic for collateral, borrowing, and repayment
library LibProtocol {
    using LibPositionManager for LibAppStorage.StorageLayout;
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using LibVaultManager for LibAppStorage.StorageLayout;

    using SafeERC20 for IERC20;

    /// @notice Deposit collateral for the caller's position, creating a position if
    ///         none exists, and rebalance it into the yield strategy.
    /// @dev Credits the amount ACTUALLY received via balance-diff (fee-on-transfer
    ///      safe); native token is taken via `msg.value`.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to deposit (or the native token sentinel).
    /// @param _amount Amount of collateral to deposit.
    function _depositCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        _validateAmount(_token, _amount);
        _callerWhitelisted(s);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);

        if (_positionId == 0) {
            _positionId = s._createPositionFor(msg.sender);
        }
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        _allowanceAndBalanceCheck(_token, _amount);

        uint256 _creditedAmount = _amount;

        if (_token != Constants.NATIVE_TOKEN) {
            uint256 _before = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
            _creditedAmount = IERC20(_token).balanceOf(address(this)) - _before;
        }

        s.s_positionCollateral[_positionId][_token] += _creditedAmount;

        LibYieldStrategy._rebalancePosition(s, _positionId, _token);
        emit CollateralDeposited(_positionId, _token, _creditedAmount);
    }

    /// @notice Withdraw collateral from the caller's position, reverting if it would
    ///         drop the position's health factor below the minimum while debt is open.
    /// @dev Rebalances out of the yield strategy before transferring the token out.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to withdraw.
    /// @param _amount Amount of collateral to withdraw.
    function _withdrawCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        uint256 _positionId = _positionIdCheck(s);
        if (s.s_positionCollateral[_positionId][_token] < _amount) revert INSUFFICIENT_BALANCE();

        s.s_positionCollateral[_positionId][_token] -= _amount;
        uint256 _healthFactor = _getHealthFactor(s, _positionId, 0);

        uint256 _debtValue = _getPositionBorrowedValue(s, _positionId) + _totalActiveDebt(s, _positionId);
        if (_debtValue > 0) {
            if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);
        }

        LibYieldStrategy._rebalanceForWithdrawal(s, _positionId, _token, _amount);

        _transferToken(_token, msg.sender, _amount);
        emit CollateralWithdrawn(_positionId, _token, _amount);
    }

    /// @notice Open a fixed-term loan against the caller's position and disburse the
    ///         principal from the token's vault to the caller.
    /// @dev Validates token support, minimum tenure, vault utilization, and the
    ///      post-borrow health factor; records the loan and bumps vault borrows.
    /// @param s The diamond storage layout.
    /// @param _token Token to borrow.
    /// @param _principal Principal amount to borrow.
    /// @param _tenureSeconds Loan tenure in seconds (must be at least one day).
    /// @return The new loan's id.
    function _takeLoan(
        LibAppStorage.StorageLayout storage s,
        address _token,
        uint256 _principal,
        uint256 _tenureSeconds
    ) internal returns (uint256) {
        uint256 _positionId = _positionIdCheck(s);
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        if (_tenureSeconds < Constants.ONE_DAY) revert TENURE_TOO_SHORT();
        if (!s._validateVaultUtlization(_token, _principal)) revert TOKEN_OVERUTILIZATION();

        (, uint256 _currentBorrowValue) = s._getTokenValueInUSD(_token, _principal);
        uint256 _healthFactor = _getHealthFactor(s, _positionId, _currentBorrowValue);
        if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);

        Loan memory _loan = Loan({
            positionId: _positionId,
            token: _token,
            principal: _principal,
            repaid: 0,
            tenureSeconds: _tenureSeconds,
            startTimestamp: block.timestamp,
            annualRateBps: s.s_interestRate,
            penaltyRateBps: s.s_penaltyRate,
            status: LoanStatus.FULFILLED
        });

        uint256 _loanId = ++s.s_nextLoanId;
        s.s_loans[_loanId] = _loan;
        s.s_positionActiveLoanIds[_positionId].push(_loanId);
        s.s_loanPrincipal[_loanId] = _principal;
        s.s_loanStartTime[_loanId] = block.timestamp;

        s._updateVaultBorrows(_loan.token, _loan.principal);

        TokenVault _vault = s.i_tokenVault[_loan.token];
        _vault.borrow(msg.sender, _loan.principal);

        emit LoanTaken(_positionId, _loanId, _loan.token, _loan.principal, _loan.tenureSeconds, _loan.annualRateBps);
        return _loanId;
    }

    /// @notice Open a fixed-term loan on behalf of a wallet from a signed,
    ///         cross-chain-attested borrow request, disbursing principal to that wallet.
    /// @dev Validates request fields, target chain/contract, optional deadline,
    ///      utilization, the off-chain signer's signature, and single-use nonce
    ///      before recording the loan.
    /// @param s The diamond storage layout.
    /// @param _request The borrow request (position, token, amount, tenure, chain, nonce, deadline, wallet).
    /// @param _signature The signer's signature over the request fields.
    /// @return The new loan's id.
    function _requestBorrow(
        LibAppStorage.StorageLayout storage s,
        BorrowRequest calldata _request,
        bytes calldata _signature
    ) internal returns (uint256) {
        if (bytes(_request.action).length == 0) revert EMPTY_STRING();
        if (_request.wallet == address(0) || _request.contractAddress == address(0)) revert ADDRESS_ZERO();
        if (_request.amount == 0) revert AMOUNT_ZERO();
        if (!s.s_supportedToken[_request.token]) revert TOKEN_NOT_SUPPORTED(_request.token);

        uint256 _storedPositionId = s._getPositionIdForUser(_request.wallet);
        if (_storedPositionId == 0) revert NO_POSITION_ID(_request.wallet);

        if (_storedPositionId != _request.positionId) {
            revert POSITION_ID_MISMATCH(_storedPositionId, _request.positionId);
        }

        if (_request.targetChainId != block.chainid) {
            revert REQUEST_BORROW_TARGET_CHAIN_MISMATCH(block.chainid, _request.targetChainId);
        }
        if (_request.contractAddress != address(this)) {
            revert REQUEST_BORROW_CONTRACT_MISMATCH(address(this), _request.contractAddress);
        }

        // Optional signature expiry: a zero deadline means no expiry; a non-zero
        // deadline bounds how long a spoke-chain-attested request stays valid on the hub.
        if (_request.deadline != 0 && block.timestamp > _request.deadline) {
            revert REQUEST_BORROW_EXPIRED(_request.deadline, block.timestamp);
        }

        if (!s._validateVaultUtlization(_request.token, _request.amount)) revert TOKEN_OVERUTILIZATION();

        _verifyBorrowSignature(s, _request, _signature);

        if (s.s_requestBorrowNonceUsed[_request.contractAddress][_request.nonce]) {
            revert REQUEST_BORROW_NONCE_USED(_request.wallet, _request.nonce);
        }
        s.s_requestBorrowNonceUsed[_request.contractAddress][_request.nonce] = true;

        Loan memory _loan = Loan({
            positionId: _request.positionId,
            token: _request.token,
            principal: _request.amount,
            repaid: 0,
            tenureSeconds: _request.tenureSeconds,
            startTimestamp: block.timestamp,
            annualRateBps: s.s_interestRate,
            penaltyRateBps: s.s_penaltyRate,
            status: LoanStatus.FULFILLED
        });

        uint256 _loanId = ++s.s_nextLoanId;
        s.s_loans[_loanId] = _loan;
        s.s_positionActiveLoanIds[_request.positionId].push(_loanId);

        s._updateVaultBorrows(_loan.token, _loan.principal);

        TokenVault _vault = s.i_tokenVault[_loan.token];
        _vault.borrow(_request.wallet, _loan.principal);

        emit LoanTaken(
            _request.positionId, _loanId, _loan.token, _loan.principal, _loan.tenureSeconds, _loan.annualRateBps
        );
        return _loanId;
    }

    /// @notice Verify that a borrow request was signed by the configured request signer.
    /// @dev Reconstructs the EIP-191 message hash over the request fields and reverts
    ///      unless the recovered address matches `s_requestBorrowSigner`.
    /// @param s The diamond storage layout.
    /// @param _request The borrow request whose fields are hashed.
    /// @param _signature The signature to recover and check.
    function _verifyBorrowSignature(
        LibAppStorage.StorageLayout storage s,
        BorrowRequest calldata _request,
        bytes calldata _signature
    ) internal view {
        if (s.s_requestBorrowSigner == address(0)) {
            revert REQUEST_BORROW_SIGNER_NOT_SET();
        }

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _request.action,
                _request.positionId,
                _request.token,
                _request.amount,
                _request.tenureSeconds,
                _request.sourceChainId,
                _request.targetChainId,
                _request.nonce,
                _request.contractAddress,
                _request.wallet,
                _request.deadline
            )
        );
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, _signature);

        if (recoveredSigner != s.s_requestBorrowSigner) {
            revert REQUEST_BORROW_INVALID_SIGNATURE(recoveredSigner);
        }
    }

    /// @notice Repay a fixed-term loan for a position using interest-first allocation.
    /// @dev Clamps `_amount` to the outstanding balance, requires it to at least
    ///      cover accrued interest + penalty, reduces principal by the principal
    ///      portion only, closes the loan when principal hits zero, and forwards the
    ///      payment to the vault split into principal and interest.
    /// @param s The diamond storage layout.
    /// @param _positionId The position that owns the loan.
    /// @param _loanId The loan to repay.
    /// @param _amount Repayment amount (clamped to outstanding debt).
    /// @return The loan's remaining principal after repayment.
    function _repayLoanFor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _loanId, uint256 _amount)
        internal
        returns (uint256)
    {
        _callerWhitelisted(s);
        Loan storage _loan = s.s_loans[_loanId];
        if (_loan.positionId != _positionId) revert NOT_LOAN_OWNER(_positionId);
        if (_loan.status != LoanStatus.FULFILLED) revert INACTIVE_LOAN();

        uint256 _loanDebt = _outstandingBalance(s, _loanId, block.timestamp);
        if (_loanDebt == 0) revert NO_OUTSTANDING_DEBT(_positionId, _loan.token);

        _allowanceAndBalanceCheck(_loan.token, _amount);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        uint256 _oldPrincipal = _loan.principal;

        // interest-first allocation: cover interest + penalty before any principal,
        // and reduce principal by the principal portion ONLY — never fold interest
        // into principal (which would re-accrue as compound interest: #12).
        uint256 _interestDue = _loanDebt - _oldPrincipal;

        // A repayment must at least cover the accrued interest + penalty. This
        // stops a dust repayment from resetting the interest anchor (escaping
        // accrued interest) — the maturity/penalty clock is already pinned to the
        // immutable origination time, so neither can be reset by a token payment (#6).
        if (_amount < _interestDue) revert REPAYMENT_BELOW_INTEREST(_amount, _interestDue);

        uint256 _principalRepaid = _amount - _interestDue;

        _loan.repaid += _amount;
        _loan.principal = _oldPrincipal - _principalRepaid;
        _loan.startTimestamp = block.timestamp;

        // If fully repaid, update loan status and move to closed loans
        if (_loan.principal == 0) {
            _loan.status = LoanStatus.REPAID;
            _removeLoanFromActive(s, _positionId, _loanId);
            s.s_positionClosedLoanIds[_positionId].push(_loanId);
        }

        TokenVault _vault = s.i_tokenVault[_loan.token];
        IERC20(_loan.token).safeTransferFrom(msg.sender, address(_vault), _amount);

        s._updateVaultRepays(_loan.token, _principalRepaid);
        _vault.repay(_principalRepaid, _amount - _principalRepaid);

        emit LoanRepayment(_positionId, _loanId, _loan.token, _amount);
        return _loan.principal;
    }

    /// @notice Repay a fixed-term loan owned by the caller's position.
    /// @dev Resolves the caller's position id, then delegates to `_repayLoanFor`.
    /// @param s The diamond storage layout.
    /// @param _loanId The loan to repay.
    /// @param _amount Repayment amount (clamped to outstanding debt).
    /// @return The loan's remaining principal after repayment.
    function _repayLoan(LibAppStorage.StorageLayout storage s, uint256 _loanId, uint256 _amount)
        internal
        returns (uint256)
    {
        uint256 _positionId = _positionIdCheck(s);
        return _repayLoanFor(s, _positionId, _loanId, _amount);
    }

    /// @notice Borrow a token against the caller's position under an open-ended,
    ///         interest-accruing debt and disburse it from the token's vault.
    /// @dev Validates token support, utilization, and the post-borrow health factor;
    ///      capitalizes prior accrued interest into the stored debt while tracking
    ///      principal separately so the borrow tally moves by principal only.
    /// @param s The diamond storage layout.
    /// @param _token Token to borrow.
    /// @param _amount Amount to borrow.
    /// @return The position's updated total debt for the token (principal + interest).
    function _borrow(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount)
        internal
        returns (uint256)
    {
        uint256 _positionId = _positionIdCheck(s);
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        if (!s._validateVaultUtlization(_token, _amount)) revert TOKEN_OVERUTILIZATION();

        (, uint256 _currentBorrowValue) = s._getTokenValueInUSD(_token, _amount);
        uint256 _healthFactor = _getHealthFactor(s, _positionId, _currentBorrowValue);

        if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);

        uint256 _tokenBorrow = s.s_positionBorrowed[_positionId][_token];
        if (_tokenBorrow == 0) {
            s.s_positionBorrowed[_positionId][_token] += _amount;
        } else {
            s.s_positionBorrowed[_positionId][_token] = _calculateUserDebt(s, _positionId, _token, _amount);
        }

        s.s_positionBorrowedLastUpdate[_positionId][_token] = block.timestamp;

        // Track principal separately and raise the borrow tally by principal only
        // (NOT capitalized interest), so it can be decremented symmetrically by
        // principal on repay. This keeps config.totalBorrows == outstanding
        // principal, which utilization / the borrow cap / interest pricing read.
        s.s_positionPrincipal[_positionId][_token] += _amount;
        s._updateVaultBorrows(_token, _amount);

        TokenVault _vault = s.i_tokenVault[_token];
        _vault.borrow(msg.sender, _amount);

        emit BorrowComplete(_positionId, _token, _amount);
        return s.s_positionBorrowed[_positionId][_token];
    }

    /// @notice Repay open-ended token debt for the caller's position.
    /// @dev Computes the interest-inclusive debt, clamps `_amount` to it, applies the
    ///      principal/interest split via `_repayStateChanges`, and forwards the
    ///      payment to the vault.
    /// @param s The diamond storage layout.
    /// @param _token Token whose debt is being repaid.
    /// @param _amount Repayment amount (clamped to outstanding debt).
    /// @return The position's remaining debt for the token after repayment.
    function _repay(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal returns (uint256) {
        uint256 _positionId = _positionIdCheck(s);

        uint256 _debt = _calculateUserDebt(s, _positionId, _token, 0);
        if (_debt == 0) revert NO_OUTSTANDING_DEBT(_positionId, _token);

        _allowanceAndBalanceCheck(_token, _amount);

        if (_amount > _debt) {
            _amount = _debt;
        }

        RepayStateChangeParams memory _params =
            RepayStateChangeParams({positionId: _positionId, token: _token, amount: _amount});
        uint256 _principalRepaid = _repayStateChanges(s, _params);
        TokenVault _vault = s.i_tokenVault[_token];

        IERC20(_token).safeTransferFrom(msg.sender, address(_vault), _amount);
        _vault.repay(_principalRepaid, _amount - _principalRepaid);

        emit Repay(_positionId, _token, _amount);
        return _calculateUserDebt(s, _positionId, _token, 0);
    }

    /// @notice Apply the storage updates for an open-ended repayment and report the
    ///         principal portion repaid.
    /// @dev Reduces stored debt by the full `_params.amount`, but decrements the
    ///      principal tally (and vault borrows) by the principal portion only.
    /// @param s The diamond storage layout.
    /// @param _params Position id, token, and repayment amount.
    /// @return _principalRepaid The principal portion of the repayment.
    function _repayStateChanges(LibAppStorage.StorageLayout storage s, RepayStateChangeParams memory _params)
        internal
        returns (uint256 _principalRepaid)
    {
        uint256 _totalDebt = _calculateUserDebt(s, _params.positionId, _params.token, 0);
        s.s_positionBorrowed[_params.positionId][_params.token] = _totalDebt - _params.amount;
        s.s_positionBorrowedLastUpdate[_params.positionId][_params.token] = block.timestamp;

        // Decrement the borrow tally by the principal portion only — the interest
        // portion of the repayment was never added to the tally at origination.
        uint256 _principalOutstanding = s.s_positionPrincipal[_params.positionId][_params.token];
        _principalRepaid = _params.amount > _principalOutstanding ? _principalOutstanding : _params.amount;
        s.s_positionPrincipal[_params.positionId][_params.token] = _principalOutstanding - _principalRepaid;
        s._updateVaultRepays(_params.token, _principalRepaid);
    }

    /// @dev Protocol's reserve slice of an interest repayment, per the token's
    ///      `reserveFactor`. Applied to all interest, including penalty.
    function _allowanceAndBalanceCheck(address _token, uint256 _amount) internal view {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();
        if (_token != Constants.NATIVE_TOKEN) {
            if (IERC20(_token).allowance(msg.sender, address(this)) < _amount) revert INSUFFICIENT_ALLOWANCE();
            if (IERC20(_token).balanceOf(msg.sender) < _amount) revert INSUFFICIENT_BALANCE();
        } else {
            if (msg.value < _amount) revert AMOUNT_MISMATCH(msg.value, _amount);
        }
    }

    function _positionIdCheck(LibAppStorage.StorageLayout storage s) internal view returns (uint256) {
        _callerWhitelisted(s);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        return _positionId;
    }

    function _callerWhitelisted(LibAppStorage.StorageLayout storage s) internal view {
        if (!s.isWhitelisted[msg.sender]) revert ADDRESS_NOT_WHITELISTED(msg.sender);
    }

    /// @notice Register a new supported collateral token with its price feed and LTV.
    /// @dev Reverts on zero addresses, an LTV below 10%, or a token already supported.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to add.
    /// @param _pricefeed Price feed for the token.
    /// @param _tokenLTV Loan-to-value ratio in basis points (minimum 1000 = 10%).
    function _addCollateralToken(
        LibAppStorage.StorageLayout storage s,
        address _token,
        address _pricefeed,
        uint16 _tokenLTV
    ) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_pricefeed == address(0)) revert ADDRESS_ZERO();
        if (_tokenLTV < 1000) revert LTV_BELOW_TEN_PERCENT();
        if (s.s_supportedCollateralTokens[_token]) revert TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL(_token);

        s.s_supportedCollateralTokens[_token] = true;
        s.s_allCollateralTokens.push(_token);
        s.s_tokenPriceFeed[_token] = _pricefeed;
        s.s_collateralTokenLTV[_token] = _tokenLTV;

        emit CollateralTokenAdded(_token);
        emit CollateralTokenLTVUpdated(_token, 0, _tokenLTV);
    }

    /// @notice Remove a token from the supported collateral set.
    /// @dev Flips support off and swap-removes the token from the collateral list.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to remove.
    function _removeCollateralToken(LibAppStorage.StorageLayout storage s, address _token) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED_AS_COLLATERAL(_token);

        s.s_supportedCollateralTokens[_token] = false;
        // delete s.s_tokenPriceFeed[_token];

        // remove from array
        uint256 length = s.s_allCollateralTokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (s.s_allCollateralTokens[i] == _token) {
                s.s_allCollateralTokens[i] = s.s_allCollateralTokens[length - 1];
                s.s_allCollateralTokens.pop();
                break;
            }
        }

        emit CollateralTokenRemoved(_token);
    }

    /// @notice Set the protocol interest and penalty rates and propagate the interest
    ///         rate to every token vault so LP accrual tracks borrower pricing.
    /// @dev Reverts if either rate is zero.
    /// @param s The diamond storage layout.
    /// @param _newInterestRate New annual interest rate, in basis points.
    /// @param _newPenaltyRate New penalty rate, in basis points.
    function _setInterestRate(LibAppStorage.StorageLayout storage s, uint16 _newInterestRate, uint16 _newPenaltyRate)
        internal
    {
        if (_newInterestRate == 0) revert AMOUNT_ZERO();
        if (_newPenaltyRate == 0) revert AMOUNT_ZERO();
        s.s_interestRate = _newInterestRate;
        s.s_penaltyRate = _newPenaltyRate;

        // Keep every vault's accrual rate in sync with the protocol rate, so
        // depositor accrual tracks what borrowers actually pay (#4 — no frozen,
        // decoupled rate).
        address[] memory _tokens = s.s_allSupportedTokens;
        for (uint256 i; i < _tokens.length; ++i) {
            TokenVault _vault = s.i_tokenVault[_tokens[i]];
            if (address(_vault) != address(0)) _vault.setInterestRate(_newInterestRate);
        }

        emit InterestRateUpdated(_newInterestRate, _newPenaltyRate);
    }

    /// @notice Update the loan-to-value ratio for a supported collateral token.
    /// @dev Reverts on a zero token, an LTV below 10%, or an unsupported token.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to update.
    /// @param _tokenNewLTV New loan-to-value ratio in basis points (minimum 1000).
    function _setCollateralTokenLtv(LibAppStorage.StorageLayout storage s, address _token, uint16 _tokenNewLTV)
        internal
    {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_tokenNewLTV < 1000) revert LTV_BELOW_TEN_PERCENT();
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED_AS_COLLATERAL(_token);

        uint16 _oldLTV = s.s_collateralTokenLTV[_token];
        s.s_collateralTokenLTV[_token] = _tokenNewLTV;

        emit CollateralTokenLTVUpdated(_token, _oldLTV, _tokenNewLTV);
    }

    /*
     * @notice Removes a loan ID from the active loans list of a position
     * @param _positionId The user position id
     * @param _loanId The ID of the loan to remove
     */
    function _removeLoanFromActive(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _loanId)
        internal
    {
        uint256[] storage list = s.s_positionActiveLoanIds[_positionId];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == _loanId) {
                list[i] = list[list.length - 1];
                list.pop();
                return;
            }
        }
    }

    /// @notice Total USD value of all collateral held by a position (no LTV haircut).
    /// @param s The diamond storage layout.
    /// @param _positionId The position to value.
    /// @return The summed USD value across every supported collateral token.
    function _getPositionCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = 0;
        address[] memory _tokens = s.s_allCollateralTokens;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _token = _tokens[i];
            uint256 _usdValue = _getPositionCollateralTokenValue(s, _positionId, _token);
            _totalValue += _usdValue;
        }
        return _totalValue;
    }

    /// @notice Remaining USD value a position can still borrow against.
    /// @dev LTV-weighted collateral value minus current open + active-loan debt,
    ///      floored at zero.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The borrowable USD headroom for the position.
    function _getPositionBorrowableCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = _getPositionUtilizableCollateralValue(s, _positionId);
        uint256 _debt = _getPositionBorrowedValue(s, _positionId) + _totalActiveDebt(s, _positionId);
        if (_debt >= _totalValue) {
            return 0;
        }
        return _totalValue - _debt;
    }

    /// @notice LTV-weighted USD value of a position's collateral (the borrowing base).
    /// @dev Each collateral's USD value is scaled by its per-token LTV.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The LTV-weighted collateral value.
    function _getPositionUtilizableCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = 0;
        address[] memory _tokens = s.s_allCollateralTokens;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _token = _tokens[i];
            uint16 _ltv = s.s_collateralTokenLTV[_token];
            uint256 _usdValue = _getPositionCollateralTokenValue(s, _positionId, _token);
            _totalValue += (_usdValue * _ltv) / Constants.BASIS_POINTS_SCALE;
        }
        return _totalValue;
    }

    function _getPositionCollateralTokenValue(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        address _token
    ) internal view returns (uint256) {
        uint256 _amount = s.s_positionCollateral[_positionId][_token];
        (, uint256 _usdValue) = s._getTokenValueInUSD(_token, _amount);
        return _usdValue;
    }

    /// @notice Total USD value of a position's open-ended (non-fixed-term) debt
    ///         across all supported tokens, including accrued interest.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The summed USD debt value.
    function _getPositionBorrowedValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = 0;
        address[] memory _tokens = s.s_allSupportedTokens;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _token = _tokens[i];
            uint256 _amount = _calculateUserDebt(s, _positionId, _token, 0);
            (, uint256 _usdValue) = s._getTokenValueInUSD(_token, _amount);
            _totalValue += _usdValue;
        }
        return _totalValue;
    }

    /// @notice Compute a position's health factor, optionally including a prospective
    ///         additional borrow.
    /// @dev Returns LTV-weighted collateral × PRECISION / total debt (open + active +
    ///      `_currentBorrowValue`); returns the max (collateral × PRECISION) when there
    ///      is no debt.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @param _currentBorrowValue Prospective extra borrow value in USD (0 to ignore).
    /// @return The health factor scaled by 1e18.
    function _getHealthFactor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _currentBorrowValue)
        internal
        view
        returns (uint256)
    {
        uint256 _collateralValue = _getPositionUtilizableCollateralValue(s, _positionId);
        uint256 _borrowedValue = _totalActiveDebt(s, _positionId) + _getPositionBorrowedValue(s, _positionId);

        _borrowedValue += _currentBorrowValue;

        if (_borrowedValue == 0) return (_collateralValue * Constants.PRECISION); // No debt means max health factor

        return (_collateralValue * Constants.PRECISION) / _borrowedValue; // Health factor with 18 decimals
    }

    /**
     * @notice Calculates the current debt for a specific user including accrued interest
     * @param _positionId The positionId of the user
     * @param _token The token the debt is debt is owed
     * @param _amount The current amount to be borrowed
     * @return debt The current debt amount including interest
     */
    function _calculateUserDebt(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        address _token,
        uint256 _amount
    ) internal view returns (uint256 debt) {
        uint256 _tokenBorrows = s.s_positionBorrowed[_positionId][_token];

        uint256 _from = s.s_positionBorrowedLastUpdate[_positionId][_token];
        uint256 _timeElapsed = block.timestamp - _from;

        // Fixed APR (#11): price interest at the protocol-set rate over the actual
        // elapsed time. Pricing off live utilization let a same-block utilization
        // spike retroactively reprice a borrower's whole interval and force a
        // wrongful liquidation; the fixed rate removes that manipulable input and
        // keeps borrower debt coupled to the vault's (same-rate) LP accrual.
        uint256 interestRate = s.s_interestRate;
        uint256 factor = ((interestRate * _timeElapsed) * 1e18) / (10000 * 365 days);
        debt = _amount + _tokenBorrows + ((_tokenBorrows * factor) / 1e18);

        return debt;
    }

    /// @notice Total USD value of a position's active fixed-term loans, including
    ///         accrued interest and any penalty.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The summed USD value of all active loans' outstanding balances.
    function _totalActiveDebt(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalDebt = 0;

        uint256[] memory _ids = s.s_positionActiveLoanIds[_positionId];
        for (uint256 i = 0; i < _ids.length; i++) {
            Loan memory _loan = s.s_loans[_ids[i]];
            (, uint256 _debt) = s._getTokenValueInUSD(_loan.token, _outstandingBalance(s, _ids[i], block.timestamp));
            _totalDebt += _debt;
        }
        return _totalDebt;
    }

    /// @notice Compute a fixed-term loan's outstanding balance (principal + accrued
    ///         interest, plus a post-maturity penalty) at a given timestamp.
    /// @dev Returns 0 for any non-FULFILLED loan. Base interest accrues from the
    ///      resettable anchor up to maturity only; the penalty accrues against the
    ///      fixed maturity.
    /// @param _loan The loan to value.
    /// @param _originationTime The IMMUTABLE loan origination timestamp. Maturity
    ///        (and therefore the penalty window) is measured against this, so a
    ///        partial repayment that resets the interest anchor `startTimestamp`
    ///        cannot move the maturity / penalty clock (#6).
    /// @param _timestamp The timestamp at which to value the loan.
    /// @return The total amount owed at `_timestamp`.
    function _outstandingBalance(Loan memory _loan, uint256 _originationTime, uint256 _timestamp)
        internal
        pure
        returns (uint256)
    {
        if (_loan.status != LoanStatus.FULFILLED) return 0;

        uint256 _maturity = _originationTime + _loan.tenureSeconds;

        // Base interest accrues from the (resettable) interest anchor up to
        // maturity — never past it, regardless of how many times it is reset.
        uint256 _interestEnd = _timestamp < _maturity ? _timestamp : _maturity;
        uint256 _interestElapsed = _interestEnd > _loan.startTimestamp ? _interestEnd - _loan.startTimestamp : 0;

        uint256 _interest = (_loan.principal * _loan.annualRateBps * _interestElapsed)
            / (Constants.BASIS_POINTS_SCALE_256 * Constants.ONE_YEAR);
        uint256 _totalOwed = _loan.principal + _interest;

        // Penalty accrues against the fixed maturity, not the moving anchor.
        if (_timestamp > _maturity) {
            uint256 penaltyTime = _timestamp - _maturity;
            uint256 penalty = (_totalOwed * (uint256(_loan.annualRateBps) + _loan.penaltyRateBps) * penaltyTime)
                / (Constants.BASIS_POINTS_SCALE_256 * Constants.ONE_YEAR);
            _totalOwed += penalty;
        }

        return _totalOwed;
    }

    /// @notice Compute a stored loan's outstanding balance at a given timestamp.
    /// @dev Resolves the immutable origination time (`s_loanStartTime`, falling back
    ///      to the loan's `startTimestamp`) and delegates to the pure overload.
    /// @param s The diamond storage layout.
    /// @param _loanId The loan to value.
    /// @param _timestamp The timestamp at which to value the loan.
    /// @return The total amount owed at `_timestamp`.
    function _outstandingBalance(LibAppStorage.StorageLayout storage s, uint256 _loanId, uint256 _timestamp)
        internal
        view
        returns (uint256)
    {
        Loan memory _loan = s.s_loans[_loanId];
        uint256 _origination = s.s_loanStartTime[_loanId] == 0 ? _loan.startTimestamp : s.s_loanStartTime[_loanId];
        return _outstandingBalance(_loan, _origination, _timestamp);
    }

    function _transferToken(address _token, address _to, uint256 _amount) internal {
        if (_to == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();

        if (_token == Constants.NATIVE_TOKEN) {
            (bool sent,) = _to.call{value: _amount}("");
            if (!sent) revert TRANSFER_FAILED();
            return;
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function _validateAmount(address _token, uint256 _amount) internal view {
        if (_amount == 0) revert AMOUNT_ZERO();
        if (_token == Constants.NATIVE_TOKEN) {
            if (msg.value != _amount) revert AMOUNT_MISMATCH(msg.value, _amount);
        }
    }

    /// @notice List the active loan ids for a position.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to query.
    /// @return The position's active loan ids.
    function _getUserActiveLoanIds(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256[] memory)
    {
        return s.s_positionActiveLoanIds[_positionId];
    }

    /// @notice List every loan id across the protocol whose status is FULFILLED.
    /// @param s The diamond storage layout.
    /// @return The ids of all currently active loans.
    function _getActiveLoanIds(LibAppStorage.StorageLayout storage s) internal view returns (uint256[] memory) {
        uint256 totalLoans = s.s_nextLoanId;
        uint256 count = 0;

        for (uint256 i = 1; i <= totalLoans; i++) {
            if (s.s_loans[i].status == LoanStatus.FULFILLED) {
                count++;
            }
        }

        uint256[] memory activeLoanIds = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 1; i <= totalLoans; i++) {
            if (s.s_loans[i].status == LoanStatus.FULFILLED) {
                activeLoanIds[index] = i;
                index++;
            }
        }

        return activeLoanIds;
    }

    /// @notice Return the full details of a loan, including its current outstanding debt.
    /// @dev `principal` and `startTimestamp` fall back to the immutable `s_loanPrincipal`
    ///      / `s_loanStartTime` records when the live loan fields have been mutated.
    /// @param s The diamond storage layout.
    /// @param _loanId The loan to read.
    /// @return positionId The owning position id.
    /// @return token The borrowed token.
    /// @return principal The loan principal (original if the live value is zero).
    /// @return repaid The cumulative amount repaid.
    /// @return tenureSeconds The loan tenure in seconds.
    /// @return startTimestamp The immutable origination timestamp.
    /// @return debt The current outstanding balance at `block.timestamp`.
    /// @return annualRateBps The annual interest rate in basis points.
    /// @return penaltyRateBps The penalty rate in basis points.
    /// @return status The loan status as a uint8.
    function _getLoanDetails(LibAppStorage.StorageLayout storage s, uint256 _loanId)
        internal
        view
        returns (
            uint256 positionId,
            address token,
            uint256 principal,
            uint256 repaid,
            uint256 tenureSeconds,
            uint256 startTimestamp,
            uint256 debt,
            uint16 annualRateBps,
            uint16 penaltyRateBps,
            uint8 status
        )
    {
        Loan memory loan = s.s_loans[_loanId];
        return (
            loan.positionId,
            loan.token,
            loan.principal == 0 ? s.s_loanPrincipal[_loanId] : loan.principal,
            loan.repaid,
            loan.tenureSeconds,
            s.s_loanStartTime[_loanId] == 0 ? loan.startTimestamp : s.s_loanStartTime[_loanId],
            _outstandingBalance(s, _loanId, block.timestamp),
            loan.annualRateBps,
            loan.penaltyRateBps,
            uint8(loan.status)
        );
    }
}

```

### contracts/libraries/LibUtils.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Constants} from "../models/Constant.sol";

/// @title LibUtils — Token decimal normalization and USD/token amount conversion helpers
library LibUtils {
    /// @notice Normalizes a token amount to 18 decimals of precision
    /// @dev Converts token amounts to standard 18-decimal representation for consistent internal calculations
    /// @param _token The token address to get decimals from (NATIVE_TOKEN returns 18)
    /// @param _amount The amount to normalize in the token's native decimals
    /// @return The normalized amount in 18 decimals
    function _normalizeTokenAmount(address _token, uint256 _amount) internal view returns (uint256) {
        uint8 _decimals = LibUtils._getTokenDecimals(_token);
        return _noramlizeToNDecimals(_amount, _decimals, 18);
    }

    /// @notice Converts a value from one decimal precision to another
    /// @dev Handles both scaling up (multiplication) and scaling down (division) based on decimal difference
    /// @param _amount The raw amount to convert
    /// @param _amountDecimal The current decimal precision of the amount
    /// @param _newDecimal The target decimal precision
    /// @return The converted amount in the new decimal precision
    /// @dev Example: _noramlizeToNDecimals(1000, 6, 18) returns 1e15 (scales up by 1e12)
    function _noramlizeToNDecimals(uint256 _amount, uint8 _amountDecimal, uint8 _newDecimal)
        internal
        pure
        returns (uint256)
    {
        if (_amountDecimal <= _newDecimal) {
            return _amount * (10 ** (_newDecimal - _amountDecimal));
        } else {
            return _amount / (10 ** (_amountDecimal - _newDecimal));
        }
    }

    /// @notice Converts a USD amount to token amount using a price feed
    /// @dev Formula: (amountInUSD * 10^tokenDecimals) / normalizedPrice
    /// where normalizedPrice = _pricePerToken scaled from pricefeedDecimals to PRECISION_SCALE (18)
    /// @param _token The token address to determine decimal places
    /// @param _amountInUSD The amount in USD (assumed to be in 18-decimal precision)
    /// @param _pricePerToken The price per token from the price feed (in _pricefeedDecimals)
    /// @param _pricefeedDecimals The decimal places of the price feed (typically 8 for Chainlink feeds)
    /// @return The equivalent token amount in the token's native decimals
    /// @dev Note: Division order is (numerator) / (denominator). Subject to integer division precision loss.
    /// @dev Example: if price = 100e8 (Chainlink format), token decimals = 6, USD amount = 1e18
    ///     result = (1e18 * 1e6) / (100e8 * 1e10) = 1e24 / 1e18 = 1e6 tokens
    function _convertUSDToTokenAmount(
        address _token,
        uint256 _amountInUSD,
        uint256 _pricePerToken,
        uint8 _pricefeedDecimals
    ) internal view returns (uint256) {
        uint8 _decimals = _getTokenDecimals(_token);
        return (_amountInUSD * (10 ** _decimals))
            / LibUtils._noramlizeToNDecimals(_pricePerToken, _pricefeedDecimals, Constants.PRECISION_SCALE);
    }

    /// @notice Retrieves the decimal precision of a token
    /// @dev Special case: NATIVE_TOKEN (address(1)) always returns 18 decimals
    /// @param _token The token address (ERC20 contract or NATIVE_TOKEN)
    /// @return The decimal places of the token (0-18 typically)
    /// @dev Reverts if _token is neither NATIVE_TOKEN nor a valid ERC20 contract
    function _getTokenDecimals(address _token) internal view returns (uint8) {
        if (_token == Constants.NATIVE_TOKEN) return 18;
        return ERC20(_token).decimals();
    }
}

```

### contracts/libraries/LibVaultManager.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {Constants} from "../models/Constant.sol";
import {VaultConfiguration} from "../models/Protocol.sol";
import "../models/Error.sol";
import "../models/Event.sol";

import {LibPositionManager} from "./LibPositionManager.sol";

import {TokenVault} from "../TokenVault.sol";

/// @title LibVaultManager — per-token vault lifecycle, deposits, and configuration
library LibVaultManager {
    using LibPositionManager for LibAppStorage.StorageLayout;
    using SafeERC20 for IERC20;

    /// @notice Deposit a supported token into its vault on behalf of a user, minting
    ///         vault shares and creating the user's position if needed.
    /// @dev Credits the amount ACTUALLY received via balance-diff (fee-on-transfer /
    ///      no-bool-return safe), bumps `totalDeposits`, then deposits into the vault.
    /// @param s The diamond storage layout.
    /// @param _from The depositor receiving shares.
    /// @param _token The token to deposit.
    /// @param _amount The amount to pull from `_from`.
    /// @return shares The vault shares minted to `_from`.
    function _deposit(LibAppStorage.StorageLayout storage s, address _from, address _token, uint256 _amount)
        internal
        returns (uint256 shares)
    {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        uint256 _positionId = s._getPositionIdForUser(_from);
        if (_positionId == 0) {
            _positionId = s._createPositionFor(_from);
        }
        TokenVault _tokenVault = s.i_tokenVault[_token];
        if (address(_tokenVault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];

        // SafeERC20 + balance-diff: credit the amount ACTUALLY received, and use
        // a transfer that tolerates no-bool-return tokens (e.g. USDT). Raw
        // `transferFrom` reverts on those (#13), and crediting the nominal amount
        // over-counts fee-on-transfer tokens against real liquidity.
        IERC20 _tokenI = IERC20(_token);
        uint256 _before = _tokenI.balanceOf(address(this));
        _tokenI.safeTransferFrom(_from, address(this), _amount);
        uint256 _received = _tokenI.balanceOf(address(this)) - _before;

        _config.totalDeposits += _received;

        _tokenI.forceApprove(address(_tokenVault), _received);
        shares = _tokenVault.deposit(_received, _from);

        emit Deposit(_positionId, _token, _received);
    }

    /// @notice Withdraw assets from a token's vault to a user, burning their shares.
    /// @dev Snapshots share supply and the deposit base before the burn, then reduces
    ///      `totalDeposits` by the PRINCIPAL portion only (proportional to shares
    ///      burned, excluding earned interest) to avoid clamping utilization to 100%.
    /// @param s The diamond storage layout.
    /// @param _to The position owner whose shares are burned and who receives assets.
    /// @param _token The token to withdraw.
    /// @param _amount The asset amount to withdraw.
    function _withdraw(LibAppStorage.StorageLayout storage s, address _to, address _token, uint256 _amount) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);

        uint256 _positionId = s._getPositionIdForUser(_to);
        if (_positionId == 0) revert NO_POSITION_ID(_to);

        TokenVault _tokenVault = s.i_tokenVault[_token];
        if (address(_tokenVault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];

        // Snapshot share supply and the deposit base BEFORE the burn so the
        // principal portion of this withdrawal can be derived proportionally.
        uint256 _supplyBefore = _tokenVault.totalSupply();
        uint256 _depositsBefore = _config.totalDeposits;

        uint256 _shares = _tokenVault.withdraw(_amount, _to, msg.sender);

        // Decrement the deposit base by the PRINCIPAL portion only — proportional
        // to the shares burned, not the interest-inclusive asset amount paid out.
        // Subtracting the full `_amount` (principal + earned interest) drifts the
        // counter below the real supplied principal and clamps it to 0, which
        // forces utilization to 100% and DoSes new borrows (#8).
        uint256 _principalOut = _supplyBefore == 0 ? 0 : (_depositsBefore * _shares) / _supplyBefore;
        if (_principalOut > _config.totalDeposits) {
            _config.totalDeposits = 0;
        } else {
            _config.totalDeposits -= _principalOut;
        }

        emit Withdrawal(_positionId, _token, _amount);
    }

    /// @notice Replace a token's vault contract with a freshly deployed one and reset
    ///         its configuration.
    /// @dev Reverts unless the existing vault is empty (no shares and no outstanding
    ///      borrows), since swapping the contract does not migrate assets.
    /// @param s The diamond storage layout.
    /// @param _token The token whose vault is being upgraded.
    /// @param _config The new vault configuration.
    /// @return The address of the newly deployed vault.
    function _upgradeVault(LibAppStorage.StorageLayout storage s, address _token, VaultConfiguration memory _config)
        internal
        returns (address)
    {
        TokenVault _oldVault = s.i_tokenVault[_token];
        if (address(_oldVault) == address(0)) {
            revert TOKEN_NOT_SUPPORTED(_token);
        }

        // Swapping the vault contract does not migrate its assets, LP shares, or
        // outstanding borrows (#10) — doing so with value present permanently
        // strands every depositor. Only allow the swap while the vault is empty
        // (pre-launch or after a full drain); routine config changes use the
        // dedicated in-place setters instead.
        uint256 _outstandingShares = _oldVault.totalSupply();
        uint256 _outstandingBorrows = s.s_tokenVaultConfig[_token].totalBorrows;
        if (_outstandingShares != 0 || _outstandingBorrows != 0) {
            revert VAULT_NOT_EMPTY(_outstandingShares, _outstandingBorrows);
        }

        TokenVault _tokenVault =
            new TokenVault(_token, _oldVault.name(), _oldVault.symbol(), address(this), s.s_interestRate, _config.reserveFactor);
        s.i_tokenVault[_token] = _tokenVault;

        s.s_tokenVaultConfig[_token] = VaultConfiguration({
            totalDeposits: 0,
            totalBorrows: 0,
            reserveFactor: _config.reserveFactor,
            baseRate: _config.baseRate,
            slopeRate: _config.slopeRate,
            optimalUtilization: _config.optimalUtilization,
            liquidationBonus: _config.liquidationBonus,
            lastUpdated: block.timestamp
        });

        emit TokenAdded(_token, address(_tokenVault));
        return address(_tokenVault);
    }

    /// @notice Deploy a new vault for a token, register it as supported, and store its
    ///         price feed and configuration.
    /// @dev Reverts on zero addresses or if the token already has a vault.
    /// @param s The diamond storage layout.
    /// @param _token The token to support.
    /// @param _pricefeed The token's price feed.
    /// @param _name The vault token name.
    /// @param _symbol The vault token symbol.
    /// @param _config The initial vault configuration.
    /// @return The address of the deployed vault.
    function _deployVault(
        LibAppStorage.StorageLayout storage s,
        address _token,
        address _pricefeed,
        string memory _name,
        string memory _symbol,
        VaultConfiguration memory _config
    ) internal returns (address) {
        if ((_token == address(0)) || (_pricefeed == address(0))) {
            revert ADDRESS_ZERO();
        }
        if (address(s.i_tokenVault[_token]) != address(0)) {
            revert TOKEN_ALREADY_SUPPORTED(_token, address(s.i_tokenVault[_token]));
        }

        TokenVault _tokenVault = new TokenVault(_token, _name, _symbol, address(this), s.s_interestRate, _config.reserveFactor);
        s.s_allSupportedTokens.push(_token);
        s.s_supportedToken[_token] = true;
        s.i_tokenVault[_token] = _tokenVault;
        s.s_tokenPriceFeed[_token] = _pricefeed;

        s.s_tokenVaultConfig[_token] = VaultConfiguration({
            totalDeposits: 0,
            totalBorrows: 0,
            reserveFactor: _config.reserveFactor,
            baseRate: _config.baseRate,
            slopeRate: _config.slopeRate,
            optimalUtilization: _config.optimalUtilization,
            liquidationBonus: _config.liquidationBonus,
            lastUpdated: block.timestamp
        });

        emit TokenAdded(_token, address(_tokenVault));
        emit TokenSupportChanged(_token, true);
        return address(_tokenVault);
    }

    /// @notice Set a token's reserve factor in both the vault config and the vault.
    /// @dev Reverts if `_reserveFactor` is zero.
    /// @param s The diamond storage layout.
    /// @param _token The token to configure.
    /// @param _reserveFactor New reserve factor in basis points.
    function _setReserveFactor(LibAppStorage.StorageLayout storage s, address _token, uint16 _reserveFactor) internal {
        if (_reserveFactor == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        _config.reserveFactor = _reserveFactor;
        TokenVault _vault = s.i_tokenVault[_token];
        if (address(_vault) != address(0)) _vault.setReserveFactor(_reserveFactor);
        emit ReserveFactorSet(_token, _reserveFactor);
    }

    /// @notice Set a token's base interest rate.
    /// @dev Reverts if `_baseRate` is zero or exceeds the configured slope rate.
    /// @param s The diamond storage layout.
    /// @param _token The token to configure.
    /// @param _baseRate New base rate in basis points.
    function _setBaseRate(LibAppStorage.StorageLayout storage s, address _token, uint16 _baseRate) internal {
        if (_baseRate == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_config.slopeRate < _baseRate) revert BAD_RATE();
        _config.baseRate = _baseRate;
        emit BaseRateSet(_token, _baseRate);
    }

    /// @notice Set a token's slope (above-optimal) interest rate.
    /// @dev Reverts if `_slopeRate` is zero or below the configured base rate.
    /// @param s The diamond storage layout.
    /// @param _token The token to configure.
    /// @param _slopeRate New slope rate in basis points.
    function _setSlopeRate(LibAppStorage.StorageLayout storage s, address _token, uint16 _slopeRate) internal {
        if (_slopeRate == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_config.baseRate > _slopeRate) revert BAD_RATE();
        _config.slopeRate = _slopeRate;
        emit SlopeRateSet(_token, _slopeRate);
    }

    /// @notice Set a token's optimal utilization point.
    /// @dev Reverts if `_optimalUtilization` is zero or below 50% (5000 bps).
    /// @param s The diamond storage layout.
    /// @param _token The token to configure.
    /// @param _optimalUtilization New optimal utilization in basis points.
    function _setOptimalUtilization(LibAppStorage.StorageLayout storage s, address _token, uint16 _optimalUtilization)
        internal
    {
        if (_optimalUtilization == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_optimalUtilization < 5000) revert BAD_RATE();
        _config.optimalUtilization = _optimalUtilization;
        emit OptimalUtilizationSet(_token, _optimalUtilization);
    }

    /// @notice Set a token's liquidation bonus.
    /// @dev Reverts if `_liquidationBonus` exceeds 10% (1000 bps).
    /// @param s The diamond storage layout.
    /// @param _token The token to configure.
    /// @param _liquidationBonus New liquidation bonus in basis points.
    function _setLiquidationBonus(LibAppStorage.StorageLayout storage s, address _token, uint16 _liquidationBonus)
        internal
    {
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_liquidationBonus > 1000) revert BAD_RATE();
        _config.liquidationBonus = _liquidationBonus;
        emit LiquidationBonusSet(_token, _liquidationBonus);
    }

    /// @notice Check whether borrowing `_amount` keeps a token's vault below its
    ///         maximum utilization.
    /// @dev Compares projected borrows against `totalDeposits * MAX_UTILIZATION`.
    /// @param s The diamond storage layout.
    /// @param _token The token to check.
    /// @param _amount The prospective additional borrow amount.
    /// @return True if the post-borrow utilization stays under the cap.
    function _validateVaultUtlization(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount)
        internal
        view
        returns (bool)
    {
        VaultConfiguration memory _config = s.s_tokenVaultConfig[_token];

        uint256 _borrows = _config.totalBorrows + _amount;
        uint256 _maxAmount = _config.totalDeposits * Constants.MAX_UTILIZATION / Constants.BASIS_POINTS_SCALE;

        return _borrows < _maxAmount;
    }

    /// @notice Increase a token vault's tracked outstanding borrows by `_amount`.
    /// @param s The diamond storage layout.
    /// @param _token The token whose borrow tally is updated.
    /// @param _amount The principal amount to add.
    function _updateVaultBorrows(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        VaultConfiguration storage _vaultConfig = s.s_tokenVaultConfig[_token];
        _vaultConfig.totalBorrows += _amount;
        _vaultConfig.lastUpdated = block.timestamp;
    }

    /// @notice Decrease a token vault's tracked outstanding borrows by `_amount`,
    ///         flooring at zero.
    /// @param s The diamond storage layout.
    /// @param _token The token whose borrow tally is updated.
    /// @param _amount The principal amount repaid.
    function _updateVaultRepays(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        VaultConfiguration storage _vaultConfig = s.s_tokenVaultConfig[_token];
        if (_amount > _vaultConfig.totalBorrows) {
            _vaultConfig.totalBorrows = 0;
        } else {
            _vaultConfig.totalBorrows -= _amount;
        }
        _vaultConfig.lastUpdated = block.timestamp;
    }

    /// @notice Disable a token for new deposits/borrows by clearing its support flag.
    /// @dev Reverts on a zero or already-unsupported token.
    /// @param s The diamond storage layout.
    /// @param _token The token to pause support for.
    function _pauseTokenSupport(LibAppStorage.StorageLayout storage s, address _token) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        s.s_supportedToken[_token] = false;
        emit TokenSupportChanged(_token, false);
    }

    /// @notice Re-enable a previously deployed token's support flag.
    /// @dev Reverts on a zero token or one with no deployed vault; no-ops if already
    ///      supported.
    /// @param s The diamond storage layout.
    /// @param _token The token to resume support for.
    function _resumeTokenSupport(LibAppStorage.StorageLayout storage s, address _token) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (address(s.i_tokenVault[_token]) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);
        if (s.s_supportedToken[_token]) return;
        s.s_supportedToken[_token] = true;
        emit TokenSupportChanged(_token, true);
    }

    function _tokenIsSupported(LibAppStorage.StorageLayout storage s, address _token) internal view returns (bool) {
        return s.s_supportedToken[_token];
    }

    function _getTokenVault(LibAppStorage.StorageLayout storage s, address _token) internal view returns (address) {
        return address(s.i_tokenVault[_token]);
    }

    /// @notice Total assets managed by a token's vault.
    /// @dev Reverts if the token has no deployed vault.
    /// @param s The diamond storage layout.
    /// @param asset The token whose vault is queried.
    /// @return The vault's `totalAssets`.
    function _getVaultTotalAssets(LibAppStorage.StorageLayout storage s, address asset)
        internal
        view
        returns (uint256)
    {
        TokenVault _tokenVault = s.i_tokenVault[asset];
        if (address(_tokenVault) == address(0)) revert TOKEN_NOT_SUPPORTED(asset);
        return _tokenVault.totalAssets();
    }

    /// @notice Return a token vault's total assets and outstanding principal borrows.
    /// @param s The diamond storage layout.
    /// @param _token The token whose vault is queried.
    /// @return The vault's total assets.
    /// @return The vault's outstanding principal borrows.
    function _getTokenVaultDetails(LibAppStorage.StorageLayout storage s, address _token)
        internal
        view
        returns (uint256, uint256)
    {
        TokenVault vault = s.i_tokenVault[_token];
        return (vault.totalAssets(), vault.totalBorrow());
    }

    /// @notice Pull the protocol's accrued interest reserve out of a token's vault.
    /// @dev Mirrors `_harvestProtocolYield`. Clamps to the available reserve.
    /// @param s The diamond storage layout.
    /// @param _token The token whose vault reserve is harvested.
    /// @param _to The recipient of the harvested reserve.
    /// @param _amount The requested amount (clamped to the available reserve).
    /// @return _harvested The amount actually withdrawn from the reserve.
    function _harvestVaultReserve(LibAppStorage.StorageLayout storage s, address _token, address _to, uint256 _amount)
        internal
        returns (uint256 _harvested)
    {
        TokenVault _vault = s.i_tokenVault[_token];
        if (address(_vault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        uint256 _available = _vault.totalProtocolReserve();
        _harvested = _amount > _available ? _available : _amount;
        if (_harvested == 0) return 0;

        _vault.withdrawReserve(_to, _harvested);
    }

    /// @notice The protocol's claimable interest reserve held in a token's vault.
    /// @dev Reverts if the token has no deployed vault.
    /// @param s The diamond storage layout.
    /// @param _token The token whose vault reserve is queried.
    /// @return The vault's `totalProtocolReserve`.
    function _getVaultReserve(LibAppStorage.StorageLayout storage s, address _token) internal view returns (uint256) {
        TokenVault _vault = s.i_tokenVault[_token];
        if (address(_vault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);
        return _vault.totalProtocolReserve();
    }

    /// @notice Socialize unrecoverable principal across LPs by writing it off the
    ///         vault's borrow base (lowers totalAssets / share price).
    /// @param s The diamond storage layout.
    /// @param _token The token whose vault absorbs the bad debt.
    /// @param _amount The bad-debt amount to write off.
    function _writeOffBadDebt(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        TokenVault _vault = s.i_tokenVault[_token];
        if (address(_vault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);
        _vault.updateBadDebt(_amount);
    }

    /// @notice Emergency stop / resume a vault's deposits.
    /// @param s The diamond storage layout.
    /// @param _token The token whose vault is paused or resumed.
    /// @param _paused New pause state (true to pause).
    function _setVaultPaused(LibAppStorage.StorageLayout storage s, address _token, bool _paused) internal {
        TokenVault _vault = s.i_tokenVault[_token];
        if (address(_vault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);
        _vault.setPaused(_paused);
    }
}

```

### contracts/libraries/LibYieldStrategy.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {Constants} from "../models/Constant.sol";
import {YieldStrategyConfig, YieldPosition} from "../models/Yield.sol";
import "../models/Error.sol";
import "../models/Event.sol";

/// @title IAavePool — Minimal Aave pool interface for supplying, withdrawing, and resolving the aToken of a reserve
interface IAavePool {
    /// @notice Returns the aToken address for the given reserve `asset`.
    function getReserveAToken(address asset) external view returns (address);
    /// @notice Supplies `amount` of `asset` to the pool on behalf of `onBehalfOf`.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    /// @notice Withdraws `amount` of `asset` from the pool to `to` and returns the amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);
}

/// @title LibYieldStrategy — Allocates position collateral to Aave and accrues user/protocol yield via a RAY-scaled index
library LibYieldStrategy {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;

    /// @notice Enables a yield strategy for `_token`, validating the Aave pool/aToken pairing and recording the allocation and protocol share, then emits YieldTokenConfigured.
    /// @param _token The collateral token to enable yield for; cannot be zero or the native token.
    /// @param _pool The Aave pool address; reverts if its reserve aToken does not match `_aToken`.
    /// @param _aToken The expected aToken for `_token` on `_pool`.
    /// @param _allocationBps The fraction of collateral allocated to yield, in basis points (<= 10000).
    /// @param _protocolShareBps The protocol's share of accrued yield, in basis points (<= 10000).
    function _configureYieldToken(
        LibAppStorage.StorageLayout storage s,
        address _token,
        address _pool,
        address _aToken,
        uint16 _allocationBps,
        uint16 _protocolShareBps
    ) internal {
        if (_token == address(0) || _pool == address(0) || _aToken == address(0)) {
            revert ADDRESS_ZERO();
        }
        if (_token == Constants.NATIVE_TOKEN) revert TOKEN_NOT_SUPPORTED(_token);
        if (_allocationBps > Constants.BASIS_POINTS_SCALE) revert YIELD_ALLOCATION_TOO_HIGH(_allocationBps);
        if (_protocolShareBps > Constants.BASIS_POINTS_SCALE) revert YIELD_ALLOCATION_TOO_HIGH(_protocolShareBps);

        try IAavePool(_pool).getReserveAToken(_token) returns (address aToken) {
            if (aToken != _aToken) revert POOL_TOKEN_MISMATCH(_pool, _aToken);
        } catch {
            revert BAD_POOL_ADDRESS(_pool);
        }

        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        _config.enabled = true;
        _config.paused = false;
        _config.aavePool = _pool;
        _config.aToken = _aToken;
        _config.allocationBps = _allocationBps;
        _config.protocolShareBps = _protocolShareBps;
        _config.lastRecordedBalance = IERC20(_aToken).balanceOf(address(this));

        emit YieldTokenConfigured(_token, _pool, _aToken, _allocationBps, _protocolShareBps);
    }

    /// @notice Pauses or unpauses the yield strategy for `_token`, reverting if the strategy is not enabled, and emits YieldTokenPaused.
    /// @param _token The token whose yield strategy is toggled.
    /// @param _paused The new paused state.
    function _setYieldPause(LibAppStorage.StorageLayout storage s, address _token, bool _paused) internal {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_config.enabled) revert YIELD_NOT_ENABLED(_token);

        _config.paused = _paused;
        emit YieldTokenPaused(_token, _paused);
    }

    /// @notice Accrues yield then moves the position's supplied principal toward its target allocation, supplying to or withdrawing from Aave as needed.
    /// @param _positionId The position to rebalance.
    /// @param _token The collateral token being rebalanced.
    function _rebalancePosition(LibAppStorage.StorageLayout storage s, uint256 _positionId, address _token) internal {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_shouldProcess(_config, _token)) {
            return;
        }

        _accrueYield(s, _token);

        YieldPosition storage _position = s.s_positionYield[_positionId][_token];
        _settlePositionYield(_config, _position);

        uint256 _collateral = s.s_positionCollateral[_positionId][_token];
        uint256 _target = (_collateral * _config.allocationBps) / Constants.BASIS_POINTS_SCALE;

        if (_target > _position.principal) {
            uint256 _toAllocate = _target - _position.principal;
            _supply(_token, _config, _toAllocate);
            _position.principal += _toAllocate;
            _config.totalPrincipal += _toAllocate;

            emit YieldAllocated(_positionId, _token, _toAllocate);
            return;
        }

        if (_position.principal > _target) {
            uint256 _toWithdraw = _position.principal - _target;
            _withdraw(_token, _config, _toWithdraw);
            _position.principal -= _toWithdraw;
            _config.totalPrincipal -= _toWithdraw;

            emit YieldReleased(_positionId, _token, _toWithdraw);
        }
    }

    /// @notice Settles the position's accrued user yield and transfers up to `_requested` of `_token` to `_recipient`, withdrawing it from Aave first.
    /// @param _positionId The position claiming yield.
    /// @param _token The yield token; strategy must be enabled and not paused.
    /// @param _recipient The address receiving the claimed tokens.
    /// @param _requested The amount requested; 0 or an over-request claims the full available amount.
    /// @return claimed The amount actually claimed and transferred.
    function _claimYield(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        address _token,
        address _recipient,
        uint256 _requested
    ) internal returns (uint256 claimed) {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_config.enabled) revert YIELD_NOT_ENABLED(_token);
        if (_config.paused) revert YIELD_TOKEN_PAUSED(_token);

        _accrueYield(s, _token);
        YieldPosition storage _position = s.s_positionYield[_positionId][_token];
        _settlePositionYield(_config, _position);

        uint256 _available = _position.userAccrued;
        if (_available == 0) revert YIELD_NOTHING_TO_CLAIM(_positionId, _token);

        claimed = _requested == 0 || _requested > _available ? _available : _requested;
        _position.userAccrued = _available - claimed;

        _withdraw(_token, _config, claimed);
        IERC20(_token).safeTransfer(_recipient, claimed);

        emit YieldClaimed(_positionId, _token, _recipient, claimed);
    }

    /// @notice Accrues yield then withdraws up to `_amount` of the protocol's accrued share of `_token` to `_recipient`.
    /// @param _token The yield token; strategy must be enabled and not paused.
    /// @param _recipient The address receiving the harvested tokens.
    /// @param _amount The amount requested; 0 or an over-request harvests the full protocol-accrued amount.
    /// @return harvested The amount actually harvested and transferred.
    function _harvestProtocolYield(
        LibAppStorage.StorageLayout storage s,
        address _token,
        address _recipient,
        uint256 _amount
    ) internal returns (uint256 harvested) {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_config.enabled) revert YIELD_NOT_ENABLED(_token);
        if (_config.paused) revert YIELD_TOKEN_PAUSED(_token);

        _accrueYield(s, _token);

        uint256 _available = _config.protocolAccrued;
        if (_available == 0) revert YIELD_NOTHING_TO_CLAIM(0, _token);

        harvested = _amount == 0 || _amount > _available ? _available : _amount;
        _config.protocolAccrued = _available - harvested;

        _withdraw(_token, _config, harvested);
        IERC20(_token).safeTransfer(_recipient, harvested);

        emit ProtocolYieldHarvested(_token, _recipient, harvested);
    }

    /// @notice Returns the position's claimable user yield for `_token`, including yield accrued but not yet recorded in storage.
    /// @param _positionId The position to query.
    /// @param _token The yield token.
    /// @return The total pending user yield for the position.
    function _pendingYield(LibAppStorage.StorageLayout storage s, uint256 _positionId, address _token)
        internal
        view
        returns (uint256)
    {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_config.enabled || _config.totalPrincipal == 0) {
            return s.s_positionYield[_positionId][_token].userAccrued;
        }

        uint256 _currentBalance = _config.aToken == address(0) ? 0 : IERC20(_config.aToken).balanceOf(address(this));
        uint256 _accrued = 0;
        if (_currentBalance > _config.lastRecordedBalance) {
            uint256 _protocolShare = ((_currentBalance - _config.lastRecordedBalance) * _config.protocolShareBps)
                / Constants.BASIS_POINTS_SCALE;
            uint256 _userShare = (_currentBalance - _config.lastRecordedBalance) - _protocolShare;
            _accrued = _userShare;
        }

        uint256 _accYield = _config.accYieldPerPrincipalRay;
        if (_accrued > 0) {
            _accYield += (_accrued * RAY) / _config.totalPrincipal;
        }

        YieldPosition storage _position = s.s_positionYield[_positionId][_token];
        if (_accYield <= _position.entryAccYieldPerPrincipalRay) {
            return _position.userAccrued;
        }
        uint256 _delta = _accYield - _position.entryAccYieldPerPrincipalRay;
        return _position.userAccrued + ((_position.principal * _delta) / RAY);
    }

    /// @notice Measures the increase in the aToken balance since the last record, splits it into user and protocol shares, and updates the per-principal yield index, emitting YieldAccrued.
    /// @param _token The yield token whose accrual is processed.
    function _accrueYield(LibAppStorage.StorageLayout storage s, address _token) internal {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_shouldProcess(_config, _token) || _config.totalPrincipal == 0) {
            _refreshRecordedBalance(_config);
            return;
        }

        uint256 _currentBalance = IERC20(_config.aToken).balanceOf(address(this));
        if (_currentBalance <= _config.lastRecordedBalance) {
            _config.lastRecordedBalance = _currentBalance;
            return;
        }

        uint256 _accrued = _currentBalance - _config.lastRecordedBalance;
        uint256 _protocolShare = (_accrued * _config.protocolShareBps) / Constants.BASIS_POINTS_SCALE;
        uint256 _userShare = _accrued - _protocolShare;

        _config.accYieldPerPrincipalRay += (_userShare * RAY) / _config.totalPrincipal;
        _config.protocolAccrued += _protocolShare;
        _config.lastRecordedBalance = _currentBalance;

        emit YieldAccrued(_token, _userShare, _protocolShare);
    }

    /// @notice Credits the position with yield accrued since its entry index and advances its entry index to the current value.
    function _settlePositionYield(YieldStrategyConfig storage _config, YieldPosition storage _position) private {
        if (_position.principal == 0) {
            _position.entryAccYieldPerPrincipalRay = _config.accYieldPerPrincipalRay;
            return;
        }

        uint256 _delta = _config.accYieldPerPrincipalRay - _position.entryAccYieldPerPrincipalRay;
        if (_delta == 0) return;

        uint256 _pending = (_position.principal * _delta) / RAY;
        _position.userAccrued += _pending;
        _position.entryAccYieldPerPrincipalRay = _config.accYieldPerPrincipalRay;
    }

    /// @notice Approves and supplies `_amount` of `_token` to the configured Aave pool, then refreshes the recorded aToken balance.
    function _supply(address _token, YieldStrategyConfig storage _config, uint256 _amount) private {
        if (_amount == 0) return;

        IERC20(_token).forceApprove(_config.aavePool, _amount);
        IAavePool(_config.aavePool).supply(_token, _amount, address(this), 0);
        _refreshRecordedBalance(_config);
    }

    /// @notice Withdraws `_amount` of `_token` from the configured Aave pool, then refreshes the recorded aToken balance.
    function _withdraw(address _token, YieldStrategyConfig storage _config, uint256 _amount) private {
        if (_amount == 0) return;
        IAavePool(_config.aavePool).withdraw(_token, _amount, address(this));
        _refreshRecordedBalance(_config);
    }

    /// @notice Rebalances a position's yield allocation while ensuring at least `_withdrawAmount` of `_token` is liquid, withdrawing extra principal from Aave to cover any balance deficit.
    /// @param _positionId The position being withdrawn from.
    /// @param _token The collateral token.
    /// @param _withdrawAmount The amount that must remain available for withdrawal; 0 defers to a normal rebalance.
    function _rebalanceForWithdrawal(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        address _token,
        uint256 _withdrawAmount
    ) internal {
        if (_withdrawAmount == 0) {
            _rebalancePosition(s, _positionId, _token);
            return;
        }

        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_shouldProcess(_config, _token)) return;

        _accrueYield(s, _token);
        YieldPosition storage _position = s.s_positionYield[_positionId][_token];
        _settlePositionYield(_config, _position);

        uint256 _collateral = s.s_positionCollateral[_positionId][_token];
        uint256 _target = (_collateral * _config.allocationBps) / Constants.BASIS_POINTS_SCALE;

        uint256 _targetWithdraw = 0;
        if (_position.principal > _target) {
            _targetWithdraw = _position.principal - _target;
        }

        uint256 _balance = IERC20(_token).balanceOf(address(this));
        uint256 _deficitWithdraw = 0;
        if (_balance < _withdrawAmount) {
            _deficitWithdraw = _withdrawAmount - _balance;
        }

        uint256 _toWithdraw = _targetWithdraw > _deficitWithdraw ? _targetWithdraw : _deficitWithdraw;

        if (_toWithdraw > 0) {
            if (_toWithdraw > _position.principal) revert YIELD_LIQUIDITY_DEFICIT(_token, _toWithdraw);

            _withdraw(_token, _config, _toWithdraw);
            _position.principal -= _toWithdraw;
            _config.totalPrincipal -= _toWithdraw;

            emit YieldReleased(_positionId, _token, _toWithdraw);
        }

        if (_target > _position.principal) {
            uint256 _toAllocate = _target - _position.principal;
            uint256 _newBalance = _toWithdraw > 0 ? _balance + _toWithdraw : _balance;

            uint256 _availableToSupply = 0;
            if (_newBalance > _withdrawAmount) {
                _availableToSupply = _newBalance - _withdrawAmount;
            }

            if (_toAllocate > _availableToSupply) {
                _toAllocate = _availableToSupply;
            }

            if (_toAllocate > 0) {
                _supply(_token, _config, _toAllocate);
                _position.principal += _toAllocate;
                _config.totalPrincipal += _toAllocate;

                emit YieldAllocated(_positionId, _token, _toAllocate);
            }
        }
    }

    /// @notice Resets `lastRecordedBalance` to the current aToken balance (or 0 when no aToken is configured) to baseline future accruals.
    function _refreshRecordedBalance(YieldStrategyConfig storage _config) private {
        if (_config.aToken == address(0)) {
            _config.lastRecordedBalance = 0;
        } else {
            _config.lastRecordedBalance = IERC20(_config.aToken).balanceOf(address(this));
        }
    }

    /// @notice Returns true only when the strategy is enabled, not paused, has an Aave pool, and `_token` is not the native token.
    function _shouldProcess(YieldStrategyConfig storage _config, address _token) private view returns (bool) {
        if (!_config.enabled || _config.paused) return false;
        if (_token == Constants.NATIVE_TOKEN) return false;
        if (_config.aavePool == address(0)) return false;
        return true;
    }
}

```

### contracts/libraries/SecurityBase.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibDiamond} from "./LibDiamond.sol";
import {ONLY_SECURITY_COUNCIL} from "../models/Error.sol";

/// @title SecurityBase — Reentrancy guard and Security Council access-control modifiers backed by diamond storage
abstract contract SecurityBase {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        // Handle uninitialized state gracefully (saves gas in init)
        if (s.s_reentrancyStatus == 0) {
            s.s_reentrancyStatus = _NOT_ENTERED;
        }
        
        require(s.s_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        s.s_reentrancyStatus = _ENTERED;
        _;
        s.s_reentrancyStatus = _NOT_ENTERED;
    }

    /**
     * @dev Restricts access to only the Diamond owner (Security Council)
     */
    modifier onlySecurityCouncil() {
        _onlySecurityCouncil();
        _;
    }

    /// @notice Reverts with ONLY_SECURITY_COUNCIL unless the caller is the Diamond owner (Security Council).
    function _onlySecurityCouncil() internal view {
        if (msg.sender != LibDiamond.contractOwner()) revert ONLY_SECURITY_COUNCIL();
    }
}

```

### contracts/models/Constant.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Constants — Protocol-wide constant values (thresholds, precision scales, and time units)
/// @dev Holds all the constant for our protocol
library Constants {
    uint16 constant LIQUIDATION_THRESHOLD = 9000;
    uint16 constant COLLATERALIZATION_RATIO = 8000;
    uint16 constant MAX_UTILIZATION = 9000;
    uint256 constant PRECISION = 1e18;
    uint256 constant PRICE_PRECISION = 1e10;
    uint256 constant MIN_HEALTH_FACTOR = 1e18;
    address constant NATIVE_TOKEN = address(1);

    // Constants to avoid magic numbers
    uint8 constant DEFAULT_COMPOUNDING_PERIODS = 12; // Monthly compounding
    uint8 constant PRECISION_SCALE = 18; // High precision for calculations
    uint16 constant BASIS_POINTS_SCALE = 1e4; // 100% = 10000 basis points
    uint256 constant BASIS_POINTS_SCALE_256 = 1e4; // 100% = 10000 basis points
    uint32 constant MAX_APR_BASIS_POINTS = 1e6; // Maximum 10000% APR
    uint256 constant ZERO = 0;

    // Chainlink price feed staleness — used as fallback when no per-feed threshold is set
    uint32 constant DEFAULT_STALENESS_THRESHOLD = 3600; // 1 hour
    uint256 constant ONE_YEAR = 365 days;
    uint256 constant ONE_DAY = 24 * 60 * 60;
}

```

### contracts/models/Error.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Error — File-level custom errors shared across the protocol's facets and libraries
// Grouped by domain: position/access, token support, borrow requests, lending, yield, and Chainlink Functions.
error ADDRESS_ZERO();
error ADDRESS_EXISTS(address userAddress);
error NO_POSITION_ID(address userAddress);
error NO_ACCESS_TO_POSITION_ID(address caller);
error POSITION_ID_MISMATCH(uint256 expected, uint256 given);
error ONLY_SECURITY_COUNCIL();
error SUBSCRIPTION_ID_NOT_SET();

error TOKEN_NOT_SUPPORTED(address asset);
error TOKEN_ALREADY_SUPPORTED(address asset, address assetVault);
error VAULT_NOT_EMPTY(uint256 shares, uint256 totalBorrows);
error TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL(address asset);
error TOKEN_NOT_SUPPORTED_AS_COLLATERAL(address asset);

error REQUEST_BORROW_SIGNER_NOT_SET();
error REQUEST_BORROW_INVALID_SIGNATURE(address recovered);
error REQUEST_BORROW_NONCE_USED(address wallet, uint256 nonce);
error REQUEST_BORROW_TARGET_CHAIN_MISMATCH(uint256 expected, uint256 provided);
error REQUEST_BORROW_CONTRACT_MISMATCH(address expected, address provided);
error REQUEST_BORROW_EXPIRED(uint256 deadline, uint256 timestamp);

error AMOUNT_ZERO();
error BAD_RATE();
error AMOUNT_MISMATCH(uint256 given, uint256 expected);
error TRANSFER_FAILED();
error INSUFFICIENT_ALLOWANCE();
error INSUFFICIENT_BALANCE();
error INSUFFICIENT_COLLATERAL();
error HEALTH_FACTOR_TOO_LOW(uint256 healthFactor);
error NOT_LIQUIDATABLE();
error NO_ACTIVE_BORROW_FOR_TOKEN(uint256 positionId, address token);
error NO_COLLATERAL_FOR_TOKEN(uint256 positionId, address token);
error NOT_LOAN_OWNER(uint256 positionId);
error ADDRESS_NOT_WHITELISTED(address caller);
error TENURE_TOO_SHORT();

error LTV_BELOW_TEN_PERCENT();
error TOKEN_OVERUTILIZATION();
error NO_OUTSTANDING_DEBT(uint256 positionId, address token);
error REPAYMENT_BELOW_INTEREST(uint256 amount, uint256 interestDue);
error INACTIVE_LOAN();

error EMPTY_STRING();
error CURRENCY_ALREADY_SUPPORTED(string currency);
error CURRENCY_NOT_SUPPORTED(string currency);

error STALE_PRICE_FEED(address priceFeed);
error INVALID_PRICE_FEED(address priceFeed);
error ZERO_PRICE_DATA();

error YIELD_ALLOCATION_TOO_HIGH(uint16 bps);
error YIELD_NOT_ENABLED(address token);
error YIELD_TOKEN_PAUSED(address token);
error YIELD_NOTHING_TO_CLAIM(uint256 positionId, address token);
error YIELD_LIQUIDITY_DEFICIT(address token, uint256 deficit);
error BAD_POOL_ADDRESS(address pool);
error POOL_TOKEN_MISMATCH(address pool, address token);

// chainlink functions error
error OnlyRouterCanFulfill();
error UnexpectedRequestID(bytes32 requestId);

```

### contracts/models/Event.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Event — File-level events emitted across the protocol's facets and libraries
// Covers position lifecycle, token/collateral management, borrowing, loans, yield, and Chainlink Functions.
event PositionIdCreated(uint256 indexed positionId, address indexed user);

event PositionIdTransferred(uint256 indexed positionId, address indexed oldAddress, address indexed newAddress);

event SecurityCouncilSet(address _newCouncil);

event TokenAdded(address indexed asset, address indexed assetVault);

event TokenSupportChanged(address indexed asset, bool isSupported);

// Vault Events
event Deposit(uint256 indexed positionId, address indexed asset, uint256 amount);
event Withdrawal(uint256 indexed positionId, address indexed asset, uint256 amount);

event CollateralDeposited(uint256 indexed positionId, address indexed token, uint256 amount);
event CollateralWithdrawn(uint256 indexed positionId, address indexed token, uint256 amount);

event CollateralTokenAdded(address indexed token);
event CollateralTokenRemoved(address indexed token);
event CollateralTokenLTVUpdated(address indexed token, uint16 tokenOldLTV, uint16 tokenNewLTV);

event LocalCurrencyAdded(string currency);
event LocalCurrencyRemoved(string currency);

event BorrowComplete(uint256 indexed positionId, address indexed token, uint256 amount);
event Repay(uint256 indexed positionId, address indexed token, uint256 amount);
event PositionLiquidated(
    uint256 indexed positionId, address indexed liquidator, address indexed token, uint256 amountToLiquidate
);

// Loan Events
event InterestRateUpdated(uint16 newInterestRate, uint16 newPenaltyRate);
event LoanTaken(
    uint256 indexed positionId,
    uint256 indexed loanId,
    address indexed token,
    uint256 principal,
    uint256 tenureSeconds,
    uint16 annualRateBps
);
event LoanRepayment(uint256 indexed positionId, uint256 indexed loanId, address indexed token, uint256 amount);
event LoanLiquidated(
    uint256 indexed positionId,
    uint256 indexed loandId,
    address indexed token,
    address liquidator,
    uint256 amountLiquidated
);

event YieldTokenConfigured(
    address indexed token, address indexed pool, address indexed aToken, uint16 allocationBps, uint16 protocolShareBps
);
event YieldTokenPaused(address indexed token, bool paused);
event YieldAllocated(uint256 indexed positionId, address indexed token, uint256 amount);
event YieldReleased(uint256 indexed positionId, address indexed token, uint256 amount);
event YieldClaimed(uint256 indexed positionId, address indexed token, address indexed to, uint256 amount);
event ProtocolYieldHarvested(address indexed token, address indexed to, uint256 amount);
event YieldAccrued(address indexed token, uint256 userAmount, uint256 protocolAmount);

// Chainlink functions events
event RequestSent(bytes32 indexed id);

event RequestFulfilled(bytes32 indexed id);

event Response(bytes32 indexed requestId, uint256 priceData, bytes response, bytes err);

event FunctionsRouterChanged(address indexed securityCouncil, bytes32 donId, address router);

event FunctionsSourceChanged(address indexed securityCouncil, bytes source);

// Vault risk/rate parameter updates
event ReserveFactorSet(address indexed token, uint16 reserveFactor);
event BaseRateSet(address indexed token, uint16 baseRate);
event SlopeRateSet(address indexed token, uint16 slopeRate);
event OptimalUtilizationSet(address indexed token, uint16 optimalUtilization);
event LiquidationBonusSet(address indexed token, uint16 liquidationBonus);

```

### contracts/models/FunctionParams.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// FunctionParams — Parameter structs used to pass grouped arguments between facet functions
// `RepayStateChangeParams` bundles the token, position, and amount applied during a repayment state change.
struct RepayStateChangeParams {
    address token;
    uint256 positionId;
    uint256 amount;
}

```

### contracts/models/Protocol.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Protocol — Core data structures for loans, borrow requests, vault config, and oracle responses
// Defines `Loan`, `BorrowRequest`, `VaultConfiguration`, the `LoanStatus` enum, and `FunctionResponse`.
struct Loan {
    uint256 positionId;
    address token;
    uint256 principal; // amount borrowed
    uint256 repaid;
    uint256 startTimestamp;
    uint256 tenureSeconds;
    uint16 annualRateBps;
    uint16 penaltyRateBps;
    LoanStatus status;
}

struct BorrowRequest {
    string action;
    uint256 positionId;
    address token;
    uint256 amount;
    uint256 tenureSeconds;
    uint256 sourceChainId;
    uint256 targetChainId;
    uint256 nonce;
    address contractAddress;
    address wallet;
    uint256 deadline; // 0 = no expiry (optional); when non-zero the hub rejects after this timestamp
}


struct VaultConfiguration {
    uint16 reserveFactor; // in basis points
    uint16 optimalUtilization; // in basis points
    uint16 baseRate; // in basis points
    uint16 slopeRate; // in basis points
    uint16 liquidationBonus; // in basis points
    uint256 totalDeposits;
    uint256 totalBorrows;
    uint256 lastUpdated; // timestamp
}

enum LoanStatus {
    REJECTED,
    FULFILLED,
    REPAID,
    LIQUIDATED
}

struct FunctionResponse {
    bool exists;
    bytes32 requestId;
    bytes responses;
    bytes err;
    uint256 priceData;
}

```

### contracts/models/Yield.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Yield — Data structures for per-token yield strategy configuration and per-position yield accounting
// `YieldStrategyConfig` holds the Aave pool/aToken wiring and accrual accumulators; `YieldPosition` tracks a position's principal and accrued yield.
struct YieldStrategyConfig {
    bool enabled;
    bool paused;
    address aavePool;
    address aToken;
    uint16 allocationBps;
    uint16 protocolShareBps;
    uint256 totalPrincipal;
    uint256 accYieldPerPrincipalRay;
    uint256 protocolAccrued;
    uint256 lastRecordedBalance;
}

struct YieldPosition {
    uint256 principal;
    uint256 userAccrued;
    uint256 entryAccYieldPerPrincipalRay;
}

```

### contracts/upgradeInitializers/DiamondInit.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {IERC165} from "../interfaces/IERC165.sol";

// It is exapected that this contract is customized if you want to deploy your diamond
// with data from a deployment script. Use the init function to initialize state variables
// of your diamond. Add parameters to the init funciton if you need to.

/// @title DiamondInit — One-time initializer that registers the diamond's supported ERC-165 interface IDs
contract DiamondInit {
    // You can add parameters to this function in order to pass in
    // data to set your own state variables
    /// @notice Registers the IERC165, IDiamondCut, IDiamondLoupe, and IERC173 interface IDs as supported in diamond storage.
    /// @dev Intended to be executed via delegatecall during a diamond deployment or upgrade.
    function init() external {
        // adding ERC165 data
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;

        // add your own state variables
        // EIP-2535 specifies that the `diamondCut` function takes two optional
        // arguments: address _init and bytes calldata _calldata
        // These arguments are used to execute an arbitrary function using delegatecall
        // in order to set state variables in the diamond during deployment or an upgrade
        // More info here: https://eips.ethereum.org/EIPS/eip-2535#diamond-interface
    }
}

```

# Senior Auditor's Mindset

This is how a senior auditor thinks. Pattern-matching catches the obvious bugs — your specialty file teaches that. The high-value bugs, the ones everyone else misses, come from HOW you reason about code, not from WHAT bugs you know.

The senior auditor's edge is not "knowing more bug patterns" — it is having internalized mental tools they reach for instinctively when something feels off, when a path seems clean, or when a conclusion comes too quickly.

This file gives you three tools. They are not steps. You reach for the right one the moment the trigger fires — see `shared-rules.md` for the binding trigger→tool protocol. Use them. Trust your discomfort.

A finding is not real until you've traced the attack with concrete values. You are an attacker, not a defender — when you find a bug, deepen the attack; never argue yourself out of one.

---

## 1. The Feynman test (FIRST — use it before anything else)

**This is the first tool. Apply it the moment you open any new function or contract — before you reason about anything else.** Code you have not Feynman'd is code you have not actually understood.

When you read code, STOP and ask: "Can I explain what this function does to someone who doesn't know Solidity?"

Try it. In plain words. The places where your explanation gets fuzzy — where you reach for Solidity jargon instead of plain meaning — are where you're papering over an assumption. That's where bugs hide.

Example: you read `_handleFeeTransfer(zrc20, fee)` and your explanation comes out as "it transfers the fee." That's not Feynman. Feynman is: "it picks up the protocol's commission off the user's payment and moves it to the treasury wallet." Now keep going: what if the payment is in ETH and the function uses an ERC20 method? Your plain-English explanation breaks. Bug.

A senior auditor doesn't trust their understanding until they can explain it without the safety net of technical vocabulary.

---

## 2. Socratic questioning

For every line of code, ask: why is this here? What does it assume? What happens if the assumption breaks?

Don't accept "because that's how it's written" as an answer. Don't accept "the function name says so" as an answer. Drill until you reach the implicit belief the code rests on. The first answer is usually a restatement. The actual assumption is two or three "whys" deeper.

Example: `if (zrc20 != _ETH_ADDRESS_) IERC20(zrc20).transferFrom(msg.sender, address(this), amount);`
- Why is `zrc20 != _ETH_ADDRESS_` checked? → because ETH isn't transferable via transferFrom.
- Why is there no else branch? → because the developer assumed ETH arrives via `msg.value`.
- Where is `msg.value` enforced to equal `amount` for the ETH path? → **nowhere**. Bug.

A senior auditor accepts no "because" without examining it.

---

## 3. Inversion

Every clean path gets a backward pass. After you understand what the code IS supposed to do, ask: how would I make it NOT do that?

Same code, attacker's eye instead of developer's eye. The developer asks "does this work?" The attacker asks "how do I break this?" Read every check and ask "what value slips past it?" Read every state update and ask "what state am I in just before this?"

A senior auditor never reads code only forward.

---

## When to reach for which tool

You don't apply these in order — except Feynman, which is always first. You reach for what the moment calls for:

- Opening any new function or contract → **Feynman** (always — before anything else)
- Trying to understand a line you don't yet → **Socratic**
- Something looks too clean → **Inversion**
- You reached a "bug" conclusion → amplify the attack (chain it, find more victims, lower the precondition cost — do NOT refute it)

The tools are how you keep yourself honest. Without them, you fall into the trap of every junior auditor: trusting your first read, accepting code that "looks right," moving on when something feels off.

Trust your discomfort. Reach for the tool. Don't stop until the discomfort has a name.
# Asymmetry Agent

You are an attacker that exploits asymmetries — between paired functions, between branches within a function, and between writers and readers of the same storage variable. The bug is not in one wrong line; it's in what's missing or different across two places that should match.

Other agents trace execution, check arithmetic, verify access control, analyze economics, scan known patterns, audit periphery, break invariants, and question assumptions. You exclusively hunt asymmetries.

## Step 1 — Enumerate every paired surface

For each contract in scope, list:

- **Operation pairs:** deposit ↔ withdraw, mint ↔ burn, lock ↔ unlock, set ↔ get, encode ↔ decode, approve ↔ pull, request ↔ fulfill, open ↔ close, stake ↔ unstake.
- **Walk pairs:** modify ↔ settle, view ↔ modify, simulate ↔ execute, pre ↔ post, init ↔ teardown.
- **Branch pairs (within a function):** native vs ERC20, normal vs admin/force, happy path vs revert path, first-time vs subsequent, empty vs non-empty input.
- **Variant pairs:** user `X()` ↔ admin `forceX()`, normal `X()` ↔ batch `XBatch()`, sync ↔ async.

For each pair, note `file:line` of both sides. This list is your work plan.

## Step 2 — Storage-write symmetry diff

For each pair, side-by-side:

1. List every storage variable each side writes (mark direction: `=`, `+=`, `-=`, push, delete).
2. List every storage variable each side reads.
3. Diff the two lists. Surface:
   - Same variable written by both, but in non-mirror direction (e.g., user variant sets `settleAmount=0`, admin variant sets `settleAmount=totalBalance` — invariant break)
   - Variable written by one side but not the other (state coupling broken)
   - Variable read by one but not the other (stale-read risk)
   - Mirror functions that mutate entirely different slot sets

The bug: developer copied structure but forgot to mirror one update.

## Step 3 — Branch-symmetry diff

For each function with internal branches (`if/else`, `if-revert`, sentinel-vs-real, native-vs-ERC20, payable vs non-payable), your job is COMPARISON: are the two branches doing equivalent work? (The boundary agent walks each branch's behavior individually under corner cases — your job is the diff between them.)

1. Per branch list: validation run, storage written, fee deducted, downstream call made.
2. Diff branches. Find:
   - Validation in A missing in B (skip-validation bug)
   - Fee deduction in A missing in B (free path)
   - Downstream call shape differs (one passes `amount`, other passes `msg.value`)
   - One branch reverts on edge, other silently no-ops

## Step 4 — Storage-variable lifecycle audit

For each storage variable used across the contract:

1. Find ALL writers.
2. Find ALL readers.
3. Flag:
   - Variable written but never read → forgotten state
   - Variable read but never written → defaults to zero silently
   - Multiple writers with different validation shapes → exploit the weakest

## Step 5 — Admin-function variants

For every admin function, check if it's a variant of a user-side function (`mint` ↔ `adminMint`, `swap` ↔ `forceSwap`, `pause/unpause` for any guarded op, `set*` for parameters that gate user behavior):

1. Diff against the user-side function for missing manipulation guards (slippage, deadline, manipulation locks), missing input validation, asymmetric state updates, missing emit.
2. The Beefy pattern: `deposit` had `onlyCompPeriods`, but `setPositionWidth` and `unpause` mirrored the same liquidity-rebalancing flow without that guard → sandwich drains TVL on admin parameter change.
3. Devs under-test admin functions. They view them as "trusted actor only" and skip layered defenses. For every admin parameter change that affects user-relevant state, ask: can a user sandwich the admin transaction?

## Step 6 — Bad symmetry (defensive checks that should not exist)

Redundant or over-restrictive checks:

- Two checks of the same invariant in adjacent functions where the second is now over-restrictive (e.g., `prepareBoxes` decrements counter, `redeemBoxes` re-checks counter > 0 → permanent DoS once preparation finishes)
- Comments saying "safety check" — frequently the safety claim is wrong
- Symmetric validation in functions that should be asymmetric

## Output fields

Add to FINDINGs:
```
pair_or_branch: which pair (deposit/withdraw, modify/settle, native-branch/ERC20-branch, admin-variant/user-version, ...) or branch you compared
asymmetry: the exact write/read/check that's in one side but missing or inverted in the other
proof: side-by-side citation showing the asymmetry with concrete state values illustrating the break
```
# Shared Scan Rules

## Bundle contents

Your bundle is four concatenated files: all in-scope source code, the SOP (HOW to think), your specialty agent (WHAT to look for), and these shared rules (output format, dedup tags, AND mandatory mental tool protocol).

Read the whole bundle once at the start. The bundle contains all in-scope source. Use Read/Grep only for cross-file searches or out-of-scope context (interfaces/, lib/, mocks/, test/) — do not re-read in-scope files for the initial scan.

**The protocol below applies continuously during source reading — not just before it.** The "read source" phase does not turn off the protocol; every trigger condition fires the moment it occurs, throughout your entire review.

When matching function names, check both `functionName` and `_functionName` (Solidity convention).

## Mental tool protocol — MANDATORY

The three tools in `senior-auditor-sop.md` are NOT optional. Each tool has a specific trigger. **When the trigger fires, you MUST emit the corresponding marker in your output stream BEFORE continuing.** No skipping. The markers live in your working text — they do NOT go into the FINDING/LEAD output blocks.

### Triggers → required markers

| Trigger (the condition) | Marker (required immediately, literal `[Tool: ...]` syntax) | Content |
|---|---|---|
| You open a new function or contract to read | `[Feynman: <name>]` | Explain what it does in plain English — no Solidity jargon, no `mload`/`assembly`/`mstore`/`safeTransfer`/etc. Use as many sentences as you need until the explanation is solid. If your wording slips back to jargon, you're papering over an assumption — keep going. Wherever your plain-English explanation gets fuzzy or you have to reach for a Solidity term to keep it accurate, mark that spot — that is where bugs hide. |
| You stop on a line whose purpose isn't immediately clear | `[Socratic: <file:line> — why?]` | A one-line question that drills past "because that's how it's written." If your first answer is a restatement of the code, ask again. Stop when the answer exposes the implicit belief the code rests on — don't pad with extra steps just to hit a quota. |
| A code path reads as clean / a check looks sufficient / a guard looks correct | `[Inversion: <function>]` | Three concrete attacker moves that attempt to defeat the path. Specific addresses/values/states, not abstractions. |

### Rules

1. **Triggers are not optional.** If the condition fires, the marker follows. Always. No skipping.
2. **Use the literal `[Tool: ...]` syntax.** The orchestrator greps your output for these tags after the run.
3. **You may emit a marker without a trigger.** Extra Feynman / Inversion markers are fine. You may NOT skip a marker after its trigger fired.
4. **The protocol applies to reasoning depth, not output volume.** Heavy use of these tools is what produces the audit work. Skipping them = surface-level scanning, which is the failure mode of every junior auditor.

The orchestrator verifies marker counts after every run. Skipped markers downgrade the value of your findings and are recorded as workflow violations.

## Cross-contract patterns

When you find a bug in one contract, **weaponize that pattern across every other contract in the bundle.** Search by function name AND by code pattern. Finding native/ERC20 confusion in `ContractA.onRevert` means you check every other contract's `onRevert` — missing a repeat instance is an audit failure.

After scanning: escalate every finding to its worst exploitable variant (DoS may hide fund theft). Then revisit every function where you found something and attack the other branches.

## Do not report

Admin-only functions doing admin things. Standard DeFi tradeoffs (MEV, rounding dust, first-depositor with MINIMUM_LIQUIDITY). Self-harm-only bugs. "Admin can rug" without a concrete mechanism.

## Output

Return findings as structured blocks:

FINDINGs have concrete, unguarded, exploitable attack paths. LEADs have real code smells with partial paths — default to LEAD over dropping.

**Every FINDING must have a `proof:` field** — concrete values, traces, or state sequences from the actual code. No proof = LEAD, no exceptions.

**One vulnerability per item.** Same root cause = one item. Different fixes needed = separate items.

```
FINDING | contract: Name | function: func | bug_class: kebab-tag | group_key: Contract | function | bug-class
path: caller → function → state change → impact
proof: concrete values/trace demonstrating the bug
description: one sentence
fix: one-sentence suggestion

LEAD | contract: Name | function: func | bug_class: kebab-tag | group_key: Contract | function | bug-class
code_smells: what you found
description: one sentence explaining trail and what remains unverified
```

The `group_key` enables deduplication: `ContractName | functionName | bug_class`. Agents may add custom fields.
