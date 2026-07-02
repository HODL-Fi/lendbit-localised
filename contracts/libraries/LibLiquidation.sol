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
        uint256 _debt = s._getPositionBorrowedValue(_positionId) + s._totalActiveDebt(_positionId);
        // Per-asset liquidation threshold (defaults to the flat 90% of raw for any
        // token governance hasn't tuned), so a volatile collateral can be given an
        // earlier trigger without touching stable-collateral behaviour.
        uint256 _threshold = s._getPositionLiquidationThresholdValue(_positionId);
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

        // Clamp the requested repayment to the loan's total outstanding balance.
        uint256 _loanDebt = s._outstandingBalance(_loanId, block.timestamp);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        uint256 _collateralHeld = s.s_positionCollateral[_loan.positionId][_collateralToken];
        uint256 _amountToLiquidate = _getAmountToLiquidate(s, _collateralToken, _loan.token, _amount);

        // Cap the seizure to the collateral actually available instead of
        // reverting. A deeply-overdue loan can accrue penalty whose bonus-adjusted
        // seizure exceeds the remaining collateral; reverting there left the loan
        // permanently un-liquidatable, so its principal became bad debt (#4a).
        // Scale the repayment down proportionally so it only pays for the
        // collateral that can actually be seized.
        if (_amountToLiquidate > _collateralHeld) {
            _amount = (_amount * _collateralHeld) / _amountToLiquidate;
            _amountToLiquidate = _collateralHeld;
        }

        uint256 _oldPrincipal = _loan.principal;

        // Pro-rata allocation across principal and interest/penalty. Every
        // liquidation retires a positive slice of principal, so a liquidator can
        // no longer repeatedly seize collateral as interest-only while principal
        // (and its regenerating penalty) survives (#4b). Interest is never folded
        // into principal (#12): `_loan.principal` only ever decreases here.
        uint256 _principalRepaid = (_amount * _oldPrincipal) / _loanDebt;
        // A liquidation must make real progress on principal. A dust repayment
        // whose principal slice rounds to zero would reset `startTimestamp` (the
        // interest anchor) while repaying nothing — the wiped-interest footgun the
        // old interest floor guarded against (#3). Reject it.
        if (_principalRepaid == 0) revert AMOUNT_ZERO();

        s.s_positionCollateral[_loan.positionId][_collateralToken] -= _amountToLiquidate;
        s.s_totalCollateralDeposited[_collateralToken] -= _amountToLiquidate;
        LibYieldStrategy._rebalanceForWithdrawal(s, _loan.positionId, _collateralToken, _amountToLiquidate);

        // update outstanding loan here
        _loan.repaid += _amount;
        _loan.principal = _oldPrincipal - _principalRepaid;
        // Do NOT reset the interest anchor on a pro-rata partial liquidation.
        // Base interest is linear in principal and keyed on `startTimestamp`, so
        // resetting it here would forgive the accrued (but unpaid) interest on the
        // surviving principal and strand the matching LP receivable in the vault's
        // `totalAccruedInterest`, overstating share price (#2). Keeping the anchor
        // makes `_outstandingBalance` return exactly the correct unpaid interest on
        // the remaining principal. On full repayment `principal == 0` and the loan
        // closes, so the anchor is moot. (The penalty clock is separately anchored
        // to the immutable `s_loanStartTime`, so it is unaffected either way.)

        // If fully repaid, update loan status and move to closed loans
        if (_loan.principal == 0) {
            _loan.status = LoanStatus.LIQUIDATED;
            s._removeLoanFromActive(_loan.positionId, _loanId);
            s.s_positionClosedLoanIds[_loan.positionId].push(_loanId);
        }

        LibVaultManager._updateVaultRepays(s, _loan.token, _principalRepaid);

        TokenVault _tokenVault = s.i_tokenVault[_loan.token];

        // Book against the amount actually received (fee-on-transfer safe, #6).
        uint256 _before = IERC20(_loan.token).balanceOf(address(_tokenVault));
        IERC20(_loan.token).safeTransferFrom(msg.sender, address(_tokenVault), _amount);
        uint256 _received = IERC20(_loan.token).balanceOf(address(_tokenVault)) - _before;
        if (_received != _amount) revert AMOUNT_MISMATCH(_received, _amount);
        _tokenVault.repayFixed(_principalRepaid, _amount - _principalRepaid, _loan.annualRateBps);

        LibProtocol._transferToken(_collateralToken, msg.sender, _amountToLiquidate);

        emit LoanLiquidated(_loan.positionId, _loanId, _collateralToken, msg.sender, _amountToLiquidate);
        emit LoanRepayment(_loan.positionId, _loanId, _loan.token, _amount);
    }

    /// @notice Liquidate a position's open-ended token debt, repaying `_amount` and
    ///         seizing the equivalent (bonus-adjusted) collateral for the liquidator.
    /// @dev Reverts if the position has no borrow for `_token`; allocates the
    ///      repayment pro-rata across principal and interest (every liquidation
    ///      must retire principal — no interest-only collateral skim), pulls the
    ///      repayment into the vault, and transfers the seized collateral to `msg.sender`.
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

        // Clamp the repayment to the position's outstanding debt (prevents the
        // `_totalDebt - _amount` underflow on an over-sized `_amount`).
        uint256 _totalDebt = s._calculateUserDebt(_positionId, _token, 0);
        if (_amount > _totalDebt) {
            _amount = _totalDebt;
        }

        uint256 _collateralHeld = s.s_positionCollateral[_positionId][_collateralToken];
        uint256 _amountToLiquidate = _getAmountToLiquidate(s, _collateralToken, _token, _amount);

        // Cap the seizure to the collateral actually available and scale the
        // repayment down proportionally, mirroring `_liquidateLoan` (#4a). Reverting
        // when the bonus-adjusted seizure exceeds the remaining collateral left a
        // deeply-underwater position liquidatable only by a liquidator who
        // pre-computes the exact maximum `_amount`; every other call reverted
        // `INSUFFICIENT_COLLATERAL`, so the collateral could strand as bad debt.
        // Capping lets any liquidation seize what collateral remains and retire the
        // matching principal slice.
        if (_amountToLiquidate > _collateralHeld) {
            _amount = (_amount * _collateralHeld) / _amountToLiquidate;
            _amountToLiquidate = _collateralHeld;
        }

        // Pro-rata principal allocation, mirroring `_liquidateLoan`. Interest-first
        // accounting here let a liquidator repay only accrued interest, seize bonus
        // collateral, and leave principal (and the vault borrow tally) untouched —
        // repeatable each block as interest re-accrues, draining collateral while
        // principal survives as bad debt (#1). Requiring a positive principal slice
        // makes every liquidation retire principal. `_repayStateChanges` keeps its
        // interest-first behaviour for ordinary `_repay`, which must not revert on
        // an interest-only user repayment.
        uint256 _principalOutstanding = s.s_positionPrincipal[_positionId][_token];
        uint256 _principalRepaid = (_amount * _principalOutstanding) / _totalDebt;
        if (_principalRepaid == 0) revert AMOUNT_ZERO();

        s.s_positionCollateral[_positionId][_collateralToken] = _collateralHeld - _amountToLiquidate;
        s.s_totalCollateralDeposited[_collateralToken] -= _amountToLiquidate;
        LibYieldStrategy._rebalanceForWithdrawal(s, _positionId, _collateralToken, _amountToLiquidate);

        // Open-ended debt bookkeeping (mirrors `_repayStateChanges`, pro-rata split).
        s.s_positionBorrowed[_positionId][_token] = _totalDebt - _amount;
        s.s_positionBorrowedLastUpdate[_positionId][_token] = block.timestamp;
        s.s_positionPrincipal[_positionId][_token] = _principalOutstanding - _principalRepaid;
        LibVaultManager._updateVaultRepays(s, _token, _principalRepaid);

        TokenVault _tokenVault = s.i_tokenVault[_token];
        // Book against the amount actually received (fee-on-transfer safe, #6).
        uint256 _before = IERC20(_token).balanceOf(address(_tokenVault));
        IERC20(_token).safeTransferFrom(msg.sender, address(_tokenVault), _amount);
        uint256 _received = IERC20(_token).balanceOf(address(_tokenVault)) - _before;
        if (_received != _amount) revert AMOUNT_MISMATCH(_received, _amount);
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
