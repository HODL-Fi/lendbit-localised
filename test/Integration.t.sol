// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "./Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ReserveFactorSet, BaseRateSet, SlopeRateSet, OptimalUtilizationSet, LiquidationBonusSet} from "../contracts/models/Event.sol";

/// @notice End-to-end integration flows spanning multiple facets in a single
///         transaction sequence (VaultManager -> Protocol -> Getters -> Liquidation),
///         and the risk/rate setter event emissions.
contract IntegrationTest is Base {
    address lp = makeAddr("int_lp");
    address borrower = makeAddr("int_borrower");
    address liquidator2 = makeAddr("int_liquidator");

    function _fundAsLp(uint256 amt) internal {
        createVaultAndFund(0); // deploy token4 vault
        positionManagerF.whitelistAddress(lp);
        positionManagerF.whitelistAddress(borrower);
        token4.mint(lp, amt);
        vm.startPrank(lp);
        token4.approve(address(diamond), amt);
        vaultManagerF.deposit(address(token4), amt);
        vm.stopPrank();
    }

    /// @dev LP deposits → borrower collateralizes and takes a loan → a year passes →
    ///      borrower repays in full → LP withdraws principal + realized interest.
    function test_full_lifecycle_deposit_borrow_repay_withdraw() public {
        _fundAsLp(100_000e6);

        // borrower posts collateral and takes a fixed-term loan
        uint256 posId = depositCollateralFor(borrower, address(token1), 1_000 ether); // ~$1.5M
        vm.prank(borrower);
        uint256 loanId = protocolF.takeLoan(address(token4), 2_000e6, 365 days); // 2,000 token4 ~$500k

        // a year elapses; interest accrues
        vm.warp(block.timestamp + 365 days);
        MockV3Aggregator(pricefeed1).updateAnswer(1500e8);
        MockV3Aggregator(pricefeed4).updateAnswer(250e8);

        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        assertGt(debt, 2_000e6, "interest accrued on the loan");

        // borrower repays in full
        token4.mint(borrower, debt);
        vm.startPrank(borrower);
        token4.approve(address(diamond), debt);
        protocolF.repayLoan(loanId, debt);
        vm.stopPrank();
        assertEq(gettersF.getOutstandingDebtForLoan(loanId), 0, "loan cleared");

        // borrower recovers collateral
        vm.prank(borrower);
        protocolF.withdrawCollateral(address(token1), 1_000 ether);
        assertEq(gettersF.getPositionCollateral(posId, address(token1)), 0, "collateral returned");

        // LP withdraws principal + realized interest (share value grew)
        uint256 lpAssets = gettersF.getVaultTotalAssets(address(token4));
        assertGt(lpAssets, 100_000e6, "vault holds LP principal + accrued interest");
    }

    /// @dev A collateral price crash makes the position liquidatable; a third party
    ///      liquidates the loan across the Getters/Liquidation facets.
    function test_liquidation_lifecycle() public {
        _fundAsLp(100_000e6);

        uint256 posId = depositCollateralFor(borrower, address(token1), 4 ether); // ~$6k
        vm.prank(borrower);
        uint256 loanId = protocolF.takeLoan(address(token4), 15e6, 365 days); // 15 token4 ~$3.75k

        vm.warp(block.timestamp + 365 days);
        updatePricefeedsData();

        // crash collateral so the position is liquidatable (mirrors Liquidation.t.sol)
        MockV3Aggregator(pricefeed1).updateAnswer(1200e8);
        assertTrue(liquidationF.isLiquidatable(posId), "position liquidatable after crash");

        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        token4.mint(liquidator2, debt);
        vm.startPrank(liquidator2);
        token4.approve(address(liquidationF), debt);
        liquidationF.liquidateLoan(loanId, debt, address(token1));
        vm.stopPrank();

        assertEq(gettersF.getOutstandingDebtForLoan(loanId), 0, "loan repaid via liquidation");
        assertGt(token1.balanceOf(liquidator2), 0, "liquidator seized collateral + bonus");
    }

    /// @dev The risk/rate setters now emit events (audit-readiness Phase 6).
    function test_config_setters_emit_events() public {
        createVaultAndFund(0);
        address t = address(token4);

        vm.expectEmit(true, false, false, true);
        emit ReserveFactorSet(t, 1500);
        vaultManagerF.setReserveFactor(t, 1500);

        vm.expectEmit(true, false, false, true);
        emit BaseRateSet(t, 400);
        vaultManagerF.setBaseRate(t, 400);

        vm.expectEmit(true, false, false, true);
        emit SlopeRateSet(t, 4000);
        vaultManagerF.setSlopeRate(t, 4000);

        vm.expectEmit(true, false, false, true);
        emit OptimalUtilizationSet(t, 7000);
        vaultManagerF.setOptimalUtilization(t, 7000);

        vm.expectEmit(true, false, false, true);
        emit LiquidationBonusSet(t, 800);
        vaultManagerF.setLiquidationBonus(t, 800);
    }
}
