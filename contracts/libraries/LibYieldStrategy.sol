// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {Constants} from "../models/Constant.sol";
import {YieldStrategyConfig, YieldPosition} from "../models/Yield.sol";
import "../models/Error.sol";
import "../models/Event.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);
}

library LibYieldStrategy {
    uint256 internal constant RAY = 1e27;

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

    function _setYieldPause(LibAppStorage.StorageLayout storage s, address _token, bool _paused) internal {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_config.enabled) revert YIELD_NOT_ENABLED(_token);

        _config.paused = _paused;
        emit YieldTokenPaused(_token, _paused);
    }

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
        bool _success = IERC20(_token).transfer(_recipient, claimed);
        if (!_success) revert TRANSFER_FAILED();

        emit YieldClaimed(_positionId, _token, _recipient, claimed);
    }

    function _harvestProtocolYield(
        LibAppStorage.StorageLayout storage s,
        address _token,
        address _recipient,
        uint256 _amount
    ) internal returns (uint256 harvested) {
        YieldStrategyConfig storage _config = s.s_yieldConfigs[_token];
        if (!_config.enabled) revert YIELD_NOT_ENABLED(_token);

        _accrueYield(s, _token);

        uint256 _available = _config.protocolAccrued;
        if (_available == 0) revert YIELD_NOTHING_TO_CLAIM(0, _token);

        harvested = _amount == 0 || _amount > _available ? _available : _amount;
        _config.protocolAccrued = _available - harvested;

        _withdraw(_token, _config, harvested);
        bool _success = IERC20(_token).transfer(_recipient, harvested);
        if (!_success) revert TRANSFER_FAILED();

        emit ProtocolYieldHarvested(_token, _recipient, harvested);
    }

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

    function _supply(address _token, YieldStrategyConfig storage _config, uint256 _amount) private {
        if (_amount == 0) return;

        IERC20(_token).approve(_config.aavePool, _amount);
        IAavePool(_config.aavePool).supply(_token, _amount, address(this), 0);
        _refreshRecordedBalance(_config);
    }

    function _withdraw(address _token, YieldStrategyConfig storage _config, uint256 _amount) private {
        if (_amount == 0) return;
        IAavePool(_config.aavePool).withdraw(_token, _amount, address(this));
        _refreshRecordedBalance(_config);
    }

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

    function _refreshRecordedBalance(YieldStrategyConfig storage _config) private {
        if (_config.aToken == address(0)) {
            _config.lastRecordedBalance = 0;
        } else {
            _config.lastRecordedBalance = IERC20(_config.aToken).balanceOf(address(this));
        }
    }

    function _shouldProcess(YieldStrategyConfig storage _config, address _token) private view returns (bool) {
        if (!_config.enabled || _config.paused) return false;
        if (_token == Constants.NATIVE_TOKEN) return false;
        if (_config.aavePool == address(0)) return false;
        return true;
    }
}
