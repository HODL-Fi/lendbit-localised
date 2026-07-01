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
