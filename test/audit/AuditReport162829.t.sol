// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base, MockV3Aggregator} from "../Base.t.sol";
import "../../contracts/models/Error.sol";

/// @title AuditReport162829 — PoC for the fixed *Lead* in
///        `lendbit-localised-pashov-ai-audit-report-20260702-162829.md`.
/// @notice Lead B: open-ended liquidation now caps an oversized bonus-adjusted
///         seizure to the collateral actually held (scaling the repayment down),
///         mirroring `_liquidateLoan`, instead of reverting `INSUFFICIENT_COLLATERAL`.
///         Fails on the pre-fix code (revert), passes on the remediated code.
contract AuditReport162829Test is Base {
    address liquidator = mkaddr("liquidator2");

    function setUp() public override {
        super.setUp();
    }

    function test_open_ended_liquidation_caps_oversized_seizure() public {
        createVaultAndFund(1_000_000e6);

        // user1: 10 token1 @ $1,500 = $15,000 collateral, LTV 8000 -> $12,000 limit.
        uint256 _positionId = depositCollateralFor(user1, address(token1), 10 ether);

        // Borrow $10,000 of token4 (@ $250 => 40 token4).
        uint256 _borrow = 40e6;
        vm.prank(user1);
        protocolF.borrow(address(token4), _borrow);

        // Collateral price crashes to $100 => collateral now 10 * $100 = $1,000,
        // far below the ~$10,000 debt. Position is deeply underwater.
        MockV3Aggregator(pricefeed1).updateAnswer(100e8);
        assertTrue(liquidationF.isLiquidatable(_positionId), "underwater position is liquidatable");

        uint256 _debt = gettersF.getBorrowDetails(_positionId, address(token4));

        // Repaying the full debt would seize ~$10,000/$100 * 1.1 = ~110 token1,
        // but only 10 token1 are held. Pre-fix: reverts INSUFFICIENT_COLLATERAL.
        // Post-fix: caps seizure to 10 token1 and scales the repayment down.
        token4.mint(liquidator, _debt);
        vm.startPrank(liquidator);
        token4.approve(address(diamond), _debt);
        liquidationF.liquidatePosition(_positionId, _debt, address(token4), address(token1));
        vm.stopPrank();

        // All available collateral was seized (no strand), and some principal retired.
        assertEq(token1.balanceOf(liquidator), 10 ether, "liquidator seized all remaining collateral");
        assertEq(
            gettersF.getPositionCollateral(_positionId, address(token1)),
            0,
            "position collateral fully seized"
        );
        // Repayment was scaled down: the liquidator spent less than the full debt,
        // so a positive token4 residual remains (not the full _debt they were minted).
        uint256 _residual = token4.balanceOf(liquidator);
        assertGt(_residual, 0, "liquidator paid less than full debt (repayment scaled down)");
        assertLt(_residual, _debt, "liquidator did pay a non-zero repayment");
    }
}
