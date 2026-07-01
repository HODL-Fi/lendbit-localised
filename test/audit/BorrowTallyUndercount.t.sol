// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

/// @notice Validates: liquidation subtracts principal+interest+penalty from
///         `config.totalBorrows`, but origination only ever added principal.
///         With ≥2 loans, liquidating one deflates the pool tally below the
///         OTHER loan's still-owed principal.
contract BorrowTallyUndercountTest is Base {
    function _openLoan(address user, uint256 collateral, uint256 principal, uint256 tenure)
        internal
        returns (uint256 loanId)
    {
        token1.mint(user, collateral);
        vm.startPrank(user);
        token1.approve(address(diamond), collateral);
        protocolF.depositCollateral(address(token1), collateral);
        loanId = protocolF.takeLoan(address(token4), principal, tenure);
        vm.stopPrank();
    }

    function test_liquidation_undercounts_config_totalBorrows() public {
        createVaultAndFund(10_000_000e18);
        protocolF.setInterestRate(5000, 5000); // 50% APR + 50% penalty

        uint256 principal = 1_000e6; // token4 is 6d, $250 -> $250k each
        uint256 collateral = 1_000 ether; // token1 $1500 -> $1.5M, comfortably collateralized

        uint256 loan1 = _openLoan(user1, collateral, principal, 1 days);
        _openLoan(user2, collateral, principal, 30 days);

        uint256 tallyAfterBorrows = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        emit log_named_uint("config.totalBorrows after 2 loans (= 2*principal)", tallyAfterBorrows);
        assertEq(tallyAfterBorrows, 2 * principal, "origination adds principal only");

        // accrue interest + penalty on loan1, then make user1 liquidatable
        // (mild drop: liquidatable, but collateral still covers a partial seize)
        vm.warp(block.timestamp + 200 days);
        MockV3Aggregator(pricefeed1).updateAnswer(400 * 1e8); // token1 $1500 -> $400
        MockV3Aggregator(pricefeed4).updateAnswer(250 * 1e8); // refresh token4 feed (avoid staleness)

        assertTrue(liquidationF.isLiquidatable(positionManagerF.getPositionIdForUser(user1)), "user1 liquidatable");

        uint256 outstanding = gettersF.getOutstandingDebtForLoan(loan1);
        emit log_named_uint("loan1 outstanding (principal+interest+penalty)", outstanding);
        assertGt(outstanding, principal, "interest+penalty accrued");

        // liquidator repays MORE than principal (1200e6 > 1000e6 principal),
        // covering the interest/penalty band — this is where the over-subtraction bites
        uint256 repay = 1_200e6;
        address liquidator = makeAddr("liquidator");
        token4.mint(liquidator, repay);
        vm.startPrank(liquidator);
        token4.approve(address(diamond), repay);
        liquidationF.liquidateLoan(loan1, repay, address(token1));
        vm.stopPrank();

        uint256 tallyAfterLiq = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;

        // Interest-first allocation (#12): repaying 1200e6 settles loan1's interest
        // band first, so only the remainder reduces principal — loan1 keeps a
        // residual principal. The tally must equal the TRUE total outstanding
        // principal = loan2's principal + loan1's remaining principal.
        uint256 loan1Remaining = _loanPrincipal(loan1);
        emit log_named_uint("config.totalBorrows after liquidating loan1", tallyAfterLiq);
        emit log_named_uint("loan2 principal + loan1 remaining principal", principal + loan1Remaining);

        // Pre-fix this under-counted (was 800e6); now it tracks true principal exactly.
        assertEq(tallyAfterLiq, principal + loan1Remaining, "tally must equal total outstanding principal");
    }

    function _loanPrincipal(uint256 loanId) internal view returns (uint256 p) {
        (,, p,,,,,,,) = gettersF.getLoanDetails(loanId);
    }
}
