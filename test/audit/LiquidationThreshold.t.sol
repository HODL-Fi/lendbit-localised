// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {BAD_RATE} from "../../contracts/models/Error.sol";

/// @notice #3 (report 2026-07-01-233007) — the liquidation trigger is now a
///         per-collateral threshold, defaulted to the historical flat 90% so
///         existing behaviour is unchanged, but tunable per asset (e.g. a tighter
///         trigger on a volatile collateral).
contract LiquidationThresholdTest is Base {
    // Default onboarding sets the threshold to 90%, preserving prior behaviour.
    function test_default_threshold_is_ninety_percent() public view {
        assertEq(gettersF.getCollateralLiquidationThreshold(address(token1)), 9000);
        assertEq(gettersF.getCollateralLiquidationThreshold(address(token2)), 9000);
    }

    // Setter invariants: LTV <= threshold <= 100%.
    function test_setter_enforces_bounds() public {
        // below the token's LTV (8000)
        vm.expectRevert(BAD_RATE.selector);
        protocolF.setCollateralLiquidationThreshold(address(token1), 7999);

        // above 100%
        vm.expectRevert(BAD_RATE.selector);
        protocolF.setCollateralLiquidationThreshold(address(token1), 10_001);

        // valid
        protocolF.setCollateralLiquidationThreshold(address(token1), 9500);
        assertEq(gettersF.getCollateralLiquidationThreshold(address(token1)), 9500);
    }

    function test_setter_is_council_only() public {
        vm.prank(user1);
        vm.expectRevert();
        protocolF.setCollateralLiquidationThreshold(address(token1), 8500);
    }

    /// @dev A position in the "dead zone" (debt above its LTV limit but below the
    ///      90% default trigger) is not liquidatable — until governance tightens
    ///      the token's threshold, which is exactly the reconfiguration knob.
    function test_tightening_threshold_triggers_earlier_liquidation() public {
        createVaultAndFund(1_000_000e6);
        protocolF.setInterestRate(2000, 500); // 20% APR

        // $15,000 of token1 collateral (10 * $1,500), LTV 80% → $12,000 borrow limit.
        uint256 _pid = depositCollateralFor(user1, address(token1), 10 ether);
        vm.prank(user1);
        protocolF.borrow(address(token4), 47e6); // ~$11,750, just under the limit
        assertFalse(liquidationF.isLiquidatable(_pid), "within LTV: not liquidatable");

        // Interest drifts debt into the dead zone (> $12,000 = 0.8C, < $13,500 = 0.9C).
        vm.warp(block.timestamp + 150 days);
        updatePricefeedsData();
        assertFalse(liquidationF.isLiquidatable(_pid), "dead zone: still not liquidatable at 90%");

        // Governance tightens token1's threshold to its LTV (80%) → the over-limit
        // position is now liquidatable, with no change to any other collateral.
        protocolF.setCollateralLiquidationThreshold(address(token1), 8000);
        assertTrue(liquidationF.isLiquidatable(_pid), "liquidatable once threshold tightened");
    }
}
