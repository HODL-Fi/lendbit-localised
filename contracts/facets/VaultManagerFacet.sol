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
