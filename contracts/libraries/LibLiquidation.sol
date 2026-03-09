// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

library LibLiquidation {
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using LibProtocol for LibAppStorage.StorageLayout;

    function _isLiquidatable(LibAppStorage.StorageLayout storage s, uint256 _positionId) internal view returns (bool) {
        uint256 _collateral = s._getPositionCollateralValue(_positionId);
        uint256 _debt = s._getPositionBorrowedValue(_positionId) + s._totalActiveDebt(_positionId);
        uint256 _threshold = _collateral * Constants.LIQUIDATION_THRESHOLD / Constants.BASIS_POINTS_SCALE_256;
        // uint256 _healthFactor = s._getHealthFactor(_positionId, 0);
        // return _healthFactor < 1e18;
        return _debt > _threshold;
    }

    function _liquidateLoan(
        LibAppStorage.StorageLayout storage s,
        uint256 _loanId,
        uint256 _amount,
        address _collateralToken
    ) internal {
        Loan storage _loan = s.s_loans[_loanId];
        if (_loan.status != LoanStatus.FULFILLED) revert INACTIVE_LOAN();
        _liquidationCheck(s, _loan.positionId, _loan.token, _collateralToken, _amount);

        uint256 _amountToLiquidate = _getAmountToLiquidate(s, _collateralToken, _loan.token, _amount);
        if (_amountToLiquidate > s.s_positionCollateral[_loan.positionId][_collateralToken]) {
            revert INSUFFICIENT_COLLATERAL();
        }

        s.s_positionCollateral[_loan.positionId][_collateralToken] -= _amountToLiquidate;
        LibYieldStrategy._rebalancePosition(s, _loan.positionId, _collateralToken);
        LibYieldStrategy._ensureSufficientIdle(s, _loan.positionId, _collateralToken, _amountToLiquidate);

        // Update loan repaid amount
        uint256 _loanDebt = s._outstandingBalance(_loanId, block.timestamp);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        // update outstanding loan here
        _loan.repaid += _amount;
        _loan.principal = _loanDebt - _amount;
        _loan.startTimestamp = block.timestamp;

        // If fully repaid, update loan status and move to closed loans
        if (_loan.principal == 0) {
            _loan.status = LoanStatus.LIQUIDATED;
            s._removeLoanFromActive(_loan.positionId, _loanId);
            s.s_positionClosedLoanIds[_loan.positionId].push(_loanId);
        }

        LibVaultManager._updateVaultRepays(s, _loan.token, _amount);

        ERC20 _tokenI = ERC20(_loan.token);
        bool _success = _tokenI.transferFrom(msg.sender, address(s.i_tokenVault[_loan.token]), _amount);
        if (!_success) revert TRANSFER_FAILED();

        LibProtocol._transferToken(_collateralToken, msg.sender, _amountToLiquidate);

        emit LoanLiquidated(_loan.positionId, _loanId, _collateralToken, msg.sender, _amountToLiquidate);
        emit LoanRepayment(_loan.positionId, _loanId, _loan.token, _amount);
    }

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
        LibYieldStrategy._rebalancePosition(s, _positionId, _collateralToken);
        LibYieldStrategy._ensureSufficientIdle(s, _positionId, _collateralToken, _amountToLiquidate);

        RepayStateChangeParams memory _params =
            RepayStateChangeParams({positionId: _positionId, token: _token, amount: _amount});
        s._repayStateChanges(_params);

        ERC20 _tokenI = ERC20(_token);
        bool _success = _tokenI.transferFrom(msg.sender, address(s.i_tokenVault[_token]), _amount);
        if (!_success) revert TRANSFER_FAILED();

        LibProtocol._transferToken(_collateralToken, msg.sender, _amountToLiquidate);

        emit PositionLiquidated(_positionId, msg.sender, _collateralToken, _amountToLiquidate);
        emit Repay(_positionId, _token, _amount);
    }

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
