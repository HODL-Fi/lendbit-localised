// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {Constants} from "../models/Constant.sol";
import {VaultConfiguration} from "../models/Protocol.sol";
import "../models/Error.sol";
import "../models/Event.sol";

import {LibPositionManager} from "./LibPositionManager.sol";

import {TokenVault} from "../TokenVault.sol";

library LibVaultManager {
    using LibPositionManager for LibAppStorage.StorageLayout;

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

        _config.totalDeposits += _amount;

        IERC20 _tokenI = IERC20(_token);
        bool success = _tokenI.transferFrom(_from, address(this), _amount);

        if (!success) revert TRANSFER_FAILED();
        _tokenI.approve(address(_tokenVault), _amount);
        shares = _tokenVault.deposit(_amount, _from);

        emit Deposit(_positionId, _token, _amount);
    }

    function _withdraw(LibAppStorage.StorageLayout storage s, address _to, address _token, uint256 _amount) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);

        uint256 _positionId = s._getPositionIdForUser(_to);
        if (_positionId == 0) revert NO_POSITION_ID(_to);

        TokenVault _tokenVault = s.i_tokenVault[_token];
        if (address(_tokenVault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];

        if (_amount > _config.totalDeposits) {
            _config.totalDeposits = 0;
        } else {
            _config.totalDeposits -= _amount;
        }

        _tokenVault.withdraw(_amount, _to, msg.sender);

        emit Withdrawal(_positionId, _token, _amount);
    }

    // function _upgradeVault(LibAppStorage.StorageLayout storage s, address _token, VaultConfiguration memory _config)
    //     internal
    //     returns (address)
    // {
    //     TokenVault _oldVault = s.i_tokenVault[_token];
    //     if (address(_oldVault) == address(0)) {
    //         revert TOKEN_NOT_SUPPORTED(_token);
    //     }

    //     TokenVault _tokenVault =
    //         new TokenVault(_token, _oldVault.name(), _oldVault.symbol(), address(this), _config.baseRate);
    //     s.i_tokenVault[_token] = _tokenVault;

    //     s.s_tokenVaultConfig[_token] = VaultConfiguration({
    //         totalDeposits: 0,
    //         totalBorrows: 0,
    //         reserveFactor: _config.reserveFactor,
    //         baseRate: _config.baseRate,
    //         slopeRate: _config.slopeRate,
    //         optimalUtilization: _config.optimalUtilization,
    //         liquidationBonus: _config.liquidationBonus,
    //         lastUpdated: block.timestamp
    //     });

    //     emit TokenAdded(_token, address(_tokenVault));
    //     return address(_tokenVault);
    // }

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

        TokenVault _tokenVault = new TokenVault(_token, _name, _symbol, address(this), _config.baseRate);
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

    function _setReserveFactor(LibAppStorage.StorageLayout storage s, address _token, uint16 _reserveFactor) internal {
        if (_reserveFactor == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        _config.reserveFactor = _reserveFactor;
    }

    function _setBaseRate(LibAppStorage.StorageLayout storage s, address _token, uint16 _baseRate) internal {
        if (_baseRate == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_config.slopeRate < _baseRate) revert BAD_RATE();
        _config.baseRate = _baseRate;
    }

    function _setSlopeRate(LibAppStorage.StorageLayout storage s, address _token, uint16 _slopeRate) internal {
        if (_slopeRate == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_config.baseRate > _slopeRate) revert BAD_RATE();
        _config.slopeRate = _slopeRate;
    }

    function _setOptimalUtilization(LibAppStorage.StorageLayout storage s, address _token, uint16 _optimalUtilization)
        internal
    {
        if (_optimalUtilization == 0) {
            revert AMOUNT_ZERO();
        }
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_optimalUtilization < 5000) revert BAD_RATE();
        _config.optimalUtilization = _optimalUtilization;
    }

    function _setLiquidationBonus(LibAppStorage.StorageLayout storage s, address _token, uint16 _liquidationBonus)
        internal
    {
        VaultConfiguration storage _config = s.s_tokenVaultConfig[_token];
        if (_liquidationBonus > 1000) revert BAD_RATE();
        _config.liquidationBonus = _liquidationBonus;
    }

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

    function _updateVaultBorrows(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        VaultConfiguration storage _vaultConfig = s.s_tokenVaultConfig[_token];
        _vaultConfig.totalBorrows += _amount;
        _vaultConfig.lastUpdated = block.timestamp;
    }

    function _updateVaultRepays(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        VaultConfiguration storage _vaultConfig = s.s_tokenVaultConfig[_token];
        if (_amount > _vaultConfig.totalBorrows) {
            _vaultConfig.totalBorrows = 0;
        } else {
            _vaultConfig.totalBorrows -= _amount;
        }
        _vaultConfig.lastUpdated = block.timestamp;
    }

    function _pauseTokenSupport(LibAppStorage.StorageLayout storage s, address _token) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        s.s_supportedToken[_token] = false;
        emit TokenSupportChanged(_token, false);
    }

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

    function _getVaultTotalAssets(LibAppStorage.StorageLayout storage s, address asset)
        internal
        view
        returns (uint256)
    {
        TokenVault _tokenVault = s.i_tokenVault[asset];
        if (address(_tokenVault) == address(0)) revert TOKEN_NOT_SUPPORTED(asset);
        return _tokenVault.totalAssets();
    }

    function _getTokenVaultDetails(LibAppStorage.StorageLayout storage s, address _token)
        internal
        view
        returns (uint256, uint256)
    {
        TokenVault vault = s.i_tokenVault[_token];
        return (vault.totalDeposit(), vault.totalBorrow());
    }
}
