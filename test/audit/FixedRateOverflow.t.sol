// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";

/// @notice Regression PoC for a Medusa-found overflow.
///
/// Root cause: in `LibProtocol._outstandingBalance`, the overdue-penalty term
/// computes `_loan.annualRateBps + _loan.penaltyRateBps`. Both fields are
/// `uint16`, so the addition is performed in `uint16` and reverts with
/// panic 0x11 whenever the SUM exceeds 65535 — even though each rate
/// individually is a legal value and `setInterestRate` accepts it (the
/// `MAX_APR_BASIS_POINTS = 1e6` guard is dead code against a uint16 param).
///
/// Impact: once such a loan is overdue, `_outstandingBalance` reverts. That
/// function is on the read path of `getOutstandingDebtForLoan`,
/// `getLoanDetails`, `getTotalActiveDebt` and `getHealthFactor`, and on the
/// write path of `repayLoan` and `liquidateLoan`. The loan can no longer be
/// repaid OR liquidated, and the borrower's whole position freezes (health
/// factor reverts → collateral cannot be withdrawn). Permanent DoS / fund lock.
///
/// Fix: widen the addition — `(uint256(_loan.annualRateBps) + _loan.penaltyRateBps)`.
contract FixedRateOverflowTest is Base {
    function _depositAndLoan(uint256 principal, uint256 tenure) internal returns (uint256 loanId) {
        uint256 collateral = 1_000_000 ether;
        token1.mint(user1, collateral);
        vm.startPrank(user1);
        token1.approve(address(diamond), collateral);
        protocolF.depositCollateral(address(token1), collateral);
        loanId = protocolF.takeLoan(address(token4), principal, tenure);
        vm.stopPrank();
    }

    function test_overdue_loan_high_rate_sum_no_overflow() public {
        createVaultAndFund(1_000_000e18);

        // sum = 60000 <= 65535 -> safe, even overdue
        protocolF.setInterestRate(30000, 30000);
        uint256 safeLoan = _depositAndLoan(1_000e6, 1 days);
        vm.warp(block.timestamp + 5 days); // overdue
        uint256 d = gettersF.getOutstandingDebtForLoan(safeLoan);
        assertGt(d, 0, "safe-rate loan should be readable when overdue");

        // sum = 80000 > 65535 -> bricks once overdue
        updatePricefeedsData(); // refresh feeds after the warp
        protocolF.setInterestRate(40000, 40000);
        uint256 badLoan = _depositAndLoan(1_000e6, 1 days);

        // readable while still within tenure (penalty branch not taken)
        assertEq(gettersF.getOutstandingDebtForLoan(badLoan), 1_000e6);

        // overdue -> after the uint256-cast fix, every consumer of
        // _outstandingBalance works (pre-fix these all reverted with panic 0x11)
        vm.warp(block.timestamp + 2 days);
        updatePricefeedsData(); // keep feeds fresh so we test the math, not staleness
        uint256 pos = positionManagerF.getPositionIdForUser(user1);

        uint256 outstanding = gettersF.getOutstandingDebtForLoan(badLoan);
        assertGt(outstanding, 1_000e6, "overdue debt accrues interest+penalty, not reverts");
        assertGt(gettersF.getTotalActiveDebt(pos), 0, "position debt is readable");

        // borrower can now repay the overdue loan
        token4.mint(user1, outstanding);
        vm.startPrank(user1);
        token4.approve(address(diamond), outstanding);
        protocolF.repayLoan(badLoan, outstanding);
        vm.stopPrank();
        assertEq(gettersF.getOutstandingDebtForLoan(badLoan), 0, "loan fully repaid");
    }
}