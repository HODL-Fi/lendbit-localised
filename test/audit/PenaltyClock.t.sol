// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";

/// @notice Validates finding #6: a partial/dust repayment can no longer reset
///         the maturity / penalty clock or escape accrued interest.
contract PenaltyClockTest is Base {
    function _openLoan() internal returns (uint256 loanId) {
        createVaultAndFund(100_000e6);
        protocolF.setInterestRate(2000, 500); // 20% APR + 5% penalty
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        loanId = protocolF.takeLoan(address(token4), 1_000e6, 1 days);
    }

    /// @dev A dust repayment on an overdue loan reverts — it cannot be used to
    ///      reset the clock, because it does not cover the accrued interest+penalty.
    function test_dust_repayment_reverts() public {
        uint256 loanId = _openLoan();

        // go far overdue so interest + penalty have accrued
        vm.warp(block.timestamp + 60 days);
        updatePricefeedsData();

        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        assertGt(debt, 1_000e6, "interest + penalty accrued past principal");

        token4.mint(user1, debt);
        vm.startPrank(user1);
        token4.approve(address(diamond), debt);
        vm.expectRevert(); // REPAYMENT_BELOW_INTEREST
        protocolF.repayLoan(loanId, 1); // dust
        vm.stopPrank();
    }

    /// @dev A valid partial repayment (covering interest+penalty) does NOT reset
    ///      the maturity: the loan stays overdue and penalty keeps accruing.
    function test_partial_repay_does_not_reset_penalty_clock() public {
        uint256 loanId = _openLoan();

        vm.warp(block.timestamp + 30 days); // overdue
        updatePricefeedsData();

        // pay just over the accrued interest+penalty (covers the interest band,
        // repays a little principal). loan remains open and overdue.
        uint256 debt0 = gettersF.getOutstandingDebtForLoan(loanId);
        uint256 pay = debt0 - 500e6; // leaves ~500e6 principal
        token4.mint(user1, pay);
        vm.startPrank(user1);
        token4.approve(address(diamond), pay);
        protocolF.repayLoan(loanId, pay);
        vm.stopPrank();

        // right after the repay
        uint256 dA = gettersF.getOutstandingDebtForLoan(loanId);
        // 10 more days
        vm.warp(block.timestamp + 10 days);
        updatePricefeedsData();
        uint256 dB = gettersF.getOutstandingDebtForLoan(loanId);

        // The loan is STILL overdue (maturity pinned to origination), so the 10-day
        // growth includes penalty (annual 20% + penalty 5% = 25%), exceeding what
        // pure base interest (20%) would add. Pre-fix the repay reset the clock and
        // the loan would have been "current" → only base interest, no penalty.
        uint256 principal = _principal(loanId);
        uint256 baseTenDay = (principal * 2000 * 10 days) / (10000 * 365 days);
        assertGt(dB - dA, baseTenDay, "penalty no longer accrues -> clock was reset (bug)");
    }

    function _principal(uint256 loanId) internal view returns (uint256 p) {
        (,, p,,,,,,,) = gettersF.getLoanDetails(loanId);
    }
}
