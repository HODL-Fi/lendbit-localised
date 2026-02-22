// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibVaultManager} from "../libraries/LibVaultManager.sol";

import {VaultConfiguration} from "../models/Protocol.sol";
import "../models/Error.sol";

contract VaultManagerFacet {
    using LibVaultManager for LibAppStorage.StorageLayout;

    function deposit(address _token, uint256 _amount) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._deposit(msg.sender, _token, _amount);
    }

    function withdraw(address _token, uint256 _amount) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._withdraw(msg.sender, _token, _amount);
    }

    function deployVault(
        address _token,
        address _pricefeed,
        string calldata _name,
        string calldata _symbol,
        VaultConfiguration calldata _config
    ) external onlySecurityCouncil returns (address) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._deployVault(_token, _pricefeed, _name, _symbol, _config);
    }

    // function upgradeVault(address _token, VaultConfiguration memory _config)
    //     external
    //     onlySecurityCouncil
    //     returns (address)
    // {
    //     LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
    //     return s._upgradeVault(_token, _config);
    // }

    // ====== Security Council Vault Config Setters ======
    // function setReserveFactor(address _token, uint16 _reserveFactor) external onlySecurityCouncil {
    //     LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
    //     LibVaultManager._setReserveFactor(s, _token, _reserveFactor);
    // }

    function setBaseRate(address _token, uint16 _baseRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibVaultManager._setBaseRate(s, _token, _baseRate);
    }

    function setSlopeRate(address _token, uint16 _slopeRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibVaultManager._setSlopeRate(s, _token, _slopeRate);
    }

    // function setOptimalUtilization(address _token, uint16 _optimalUtilization) external onlySecurityCouncil {
    //     LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
    //     LibVaultManager._setOptimalUtilization(s, _token, _optimalUtilization);
    // }

    // function setLiquidationBonus(address _token, uint16 _liquidationBonus) external onlySecurityCouncil {
    //     LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
    //     LibVaultManager._setLiquidationBonus(s, _token, _liquidationBonus);
    // }

    function pauseTokenSupport(address _token) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._pauseTokenSupport(_token);
    }

    function resumeTokenSupport(address _token) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._resumeTokenSupport(_token);
    }

    function getTokenVaultConfig(address _token) external view returns (VaultConfiguration memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_tokenVaultConfig[_token];
    }

    function getTokenVaultDetails(address _token) external view returns (uint256, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        VaultConfiguration memory _config = s.s_tokenVaultConfig[_token];
        return (_config.totalDeposits, _config.totalBorrows);
    }

    modifier onlySecurityCouncil() {
        _onlySecurityCouncil();
        _;
    }

    function _onlySecurityCouncil() internal view {
        if (msg.sender != LibDiamond.contractOwner()) revert ONLY_SECURITY_COUNCIL();
    }
}
