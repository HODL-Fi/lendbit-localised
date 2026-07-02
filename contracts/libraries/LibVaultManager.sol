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
        // Honour the whitelist on every deposit, not just when creating a new
        // position — otherwise a user blacklisted after opening a position could
        // still mint vault shares (#8). Mirrors `_depositCollateral`.
        s._addressIsWhitelisted(_from);
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

        // Credit utilization accounting from what the VAULT actually receives on
        // the second hop, not the diamond's first-hop receipt. For a fee-on-
        // transfer token the vault gets less than `_received`, so crediting the
        // first-hop amount would overstate `totalDeposits` and inflate the borrow
        // cap above real liquid assets (#4).
        _tokenI.forceApprove(address(_tokenVault), _received);
        uint256 _vaultBefore = _tokenI.balanceOf(address(_tokenVault));
        shares = _tokenVault.deposit(_received, _from);
        uint256 _vaultReceived = _tokenI.balanceOf(address(_tokenVault)) - _vaultBefore;

        _config.totalDeposits += _vaultReceived;

        emit Deposit(_positionId, _token, _vaultReceived);
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
        // Honour the whitelist/blacklist freeze on this value-extracting path, like
        // deposit, collateral withdrawal, and yield claim already do. Otherwise a
        // user blacklisted after depositing could still burn shares and pull vault
        // assets — the LP-withdrawal twin of the deposit-side blacklist gap (report
        // 2026-07-02 18:17 #1). This is the USER freeze; it is orthogonal to (and
        // composes with) the token-support-pause exit path below.
        s._addressIsWhitelisted(_to);
        // Deliberately NOT gated on `s_supportedToken`. Pausing/delisting a token
        // (`_pauseTokenSupport`) must stop new deposits and borrows, but it must not
        // trap existing LPs — a withdrawal only returns their own deposited principal
        // and reduces protocol exposure, so it stays available even while support is
        // paused (see lead: pausing token support blocks LP withdrawals). A token
        // that never had a vault still reverts here on the zero-vault check; that
        // check runs before the position lookup so an un-vaulted token surfaces
        // TOKEN_NOT_SUPPORTED rather than NO_POSITION_ID.
        TokenVault _tokenVault = s.i_tokenVault[_token];
        if (address(_tokenVault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        uint256 _positionId = s._getPositionIdForUser(_to);
        if (_positionId == 0) revert NO_POSITION_ID(_to);

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
        // Same config bounds as `_deployVault` (#7).
        _validateVaultConfigBounds(_config);

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
        // Bound the initial config to the same limits the in-place setters enforce,
        // so a vault can never be deployed with an unsafe bonus/reserve that only
        // the setters would reject (#7). Bonus <= 10%; reserve factor <= 100%
        // (a reserve factor above 100% underflows the LP-interest split).
        _validateVaultConfigBounds(_config);

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

    /// @notice Reverts unless the vault config's liquidation bonus and reserve
    ///         factor are within the same bounds the in-place setters enforce.
    /// @dev Bonus must be <= 1000 (10%, matching `_setLiquidationBonus`); reserve
    ///      factor must be <= BASIS_POINTS_SCALE (100%, matching
    ///      `TokenVault.setReserveFactor`) — a factor above 100% underflows the
    ///      LP-interest split in `TokenVault._pendingInterest`.
    /// @param _config The vault configuration to validate.
    function _validateVaultConfigBounds(VaultConfiguration memory _config) internal pure {
        if (_config.liquidationBonus > 1000) revert BAD_RATE();
        if (_config.reserveFactor > Constants.BASIS_POINTS_SCALE) revert BAD_RATE();
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

        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];

        // The principal portion of the write-off (the interest remainder is written
        // off the vault's `totalAccruedInterest`, never counted in `totalDeposits`).
        // Captured BEFORE `_updateVaultRepays` decrements the borrow tally.
        uint256 _principalLoss = _amount > _config.totalBorrows ? _config.totalBorrows : _amount;

        // Mirror the write-off in the diamond-side utilization NUMERATOR.
        // `updateBadDebt` clears the unrecoverable principal from the vault's
        // `totalBorrows`, but `config.totalBorrows` (what `_validateVaultUtlization`
        // reads) is a separate counter — leaving it inflated bricks new borrows (#3,
        // 15:06 report). `_updateVaultRepays` floors at zero.
        _updateVaultRepays(s, _token, _amount);

        // Mirror the loss in the utilization DENOMINATOR too. The socialized bad
        // debt is capital that left the vault and will not return, so the real
        // deposit base shrank by `_principalLoss`. Reducing only the numerator left
        // `totalDeposits` overstating available liquidity, so utilization read low
        // and a new borrow could be admitted above the true 90% cap of liquid assets
        // (report 2026-07-02 18:17 #3). Floor at zero for safety.
        _config.totalDeposits = _principalLoss > _config.totalDeposits ? 0 : _config.totalDeposits - _principalLoss;
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
