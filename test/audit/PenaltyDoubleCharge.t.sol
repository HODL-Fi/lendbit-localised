// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";

/// @notice Regression for M-02: a partial repayment on an overdue loan must settle
///         the penalty accrued to date and NOT re-charge that same window on the
///         surviving principal. Complements PenaltyClock.t.sol, which only checks the
///         clock is not reset EARLY — it never checked that paid penalty is not
///         re-charged. Both directions are asserted here: no double-charge, and no
///         interest-dodge (penalty keeps accruing from the settlement point).
contract PenaltyDoubleChargeTest is Base {
    uint256 constant PRINCIPAL = 1_000e6;

    function _openOverdueLoan() internal returns (uint256 loanId) {
        createVaultAndFund(100_000e6);
        protocolF.setInterestRate(2000, 500); // 20% APR + 5% penalty
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        loanId = protocolF.takeLoan(address(token4), PRINCIPAL, 1 days);

        vm.warp(block.timestamp + 30 days); // far overdue
        updatePricefeedsData();
    }

    /// @dev After a partial repay that leaves 500e6 principal, the debt in the SAME
    ///      block must be exactly the surviving principal — the interest+penalty band
    ///      was just paid, so there is nothing left to owe yet.
    ///      Pre-fix: the full ~29-day penalty window was instantly re-applied to the
    ///      surviving 500e6 (~+9.9e6), double-charging the borrower.
    function test_no_penalty_recharge_immediately_after_partial_repay() public {
        uint256 loanId = _openOverdueLoan();

        uint256 debt0 = gettersF.getOutstandingDebtForLoan(loanId);
        assertGt(debt0, PRINCIPAL, "interest + penalty must have accrued past principal");

        // Interest-first: this covers the whole interest+penalty band and repays
        // exactly 500e6 of principal, leaving 500e6.
        uint256 pay = debt0 - 500e6;
        token4.mint(user1, pay);
        vm.startPrank(user1);
        token4.approve(address(diamond), pay);
        protocolF.repayLoan(loanId, pay);
        vm.stopPrank();

        uint256 debt1 = gettersF.getOutstandingDebtForLoan(loanId);
        assertEq(debt1, 500e6, "surviving principal only; no re-charged penalty (M-02)");
    }

    /// @dev The penalty clock is NOT dodged: the loan is still overdue, so warping
    ///      forward accrues penalty (25% combined) on the surviving principal — more
    ///      than base interest (20%) alone would add. This is the property the
    ///      immutable-maturity design protected, and it must still hold.
    function test_penalty_still_accrues_from_settlement_point() public {
        uint256 loanId = _openOverdueLoan();

        uint256 debt0 = gettersF.getOutstandingDebtForLoan(loanId);
        uint256 pay = debt0 - 500e6;
        token4.mint(user1, pay);
        vm.startPrank(user1);
        token4.approve(address(diamond), pay);
        protocolF.repayLoan(loanId, pay);
        vm.stopPrank();

        uint256 debtA = gettersF.getOutstandingDebtForLoan(loanId); // == 500e6
        vm.warp(block.timestamp + 10 days);
        updatePricefeedsData();
        uint256 debtB = gettersF.getOutstandingDebtForLoan(loanId);

        // 10-day growth on 500e6 principal. Penalty (25%) must exceed base-only (20%).
        uint256 survivingP = 500e6;
        uint256 baseOnly = (survivingP * 2000 * 10 days) / (10000 * 365 days);
        assertGt(debtB - debtA, baseOnly, "penalty must resume from the settlement point (no dodge)");
    }
}
