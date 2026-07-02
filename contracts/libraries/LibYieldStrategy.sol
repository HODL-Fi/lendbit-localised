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

        // Distribute any yield accrued under the CURRENT parameters before
        // overwriting them. Reconfiguring an already-enabled token rebaselines
        // `lastRecordedBalance` to the live aToken balance below; without accruing
        // first, the (currentBalance − lastRecordedBalance) delta earned since the
        // last touch is silently erased instead of credited to holders (see lead:
        // reconfiguration skips checkpointing). No-ops for a fresh token
        // (`_shouldProcess` is false until enabled). Uses the pre-existing config,
        // so it must run before the fields are reassigned.
        _accrueYield(s, _token);

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
