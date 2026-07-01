// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

/// @notice Finding #11: the pooled `borrow()` path priced a borrower's whole
///         elapsed interval at the spot utilization rate sampled NOW, so a
///         same-block utilization spike retroactively repriced an otherwise
///         healthy position. The fix pins `_calculateUserDebt` to the protocol's
///         fixed APR, so a borrower's debt is independent of utilization.
contract PooledDebtUtilizationRepriceTest is Base {
    address borrowerA = makeAddr("borrowerA");
    address whaleB = makeAddr("whaleB");

    function _setup() internal returns (uint256 posA, address token) {
        createVaultAndFund(1_000_000e6); // token4, 6 decimals, $250 feed by default
        positionManagerF.whitelistAddress(borrowerA);
        positionManagerF.whitelistAddress(whaleB);
        token = address(token4);
        MockV3Aggregator(pricefeed4).updateAnswer(1e8); // retag token4 to $1 for easy sizing

        // Borrower A takes a small pooled borrow at ~0% utilization
        posA = depositCollateralFor(borrowerA, address(token1), 100 ether); // $150k collateral
        vm.prank(borrowerA);
        protocolF.borrow(token, 100e6); // $100 debt, low utilization
    }

    function test_utilization_spike_does_not_reprice_existing_borrower() public {
        (uint256 posA, address token) = _setup();

        vm.warp(block.timestamp + 30 days);
        // refresh feeds so post-warp health checks aren't stale
        MockV3Aggregator(pricefeed1).updateAnswer(1500e8);
        MockV3Aggregator(pricefeed4).updateAnswer(1e8);

        uint256 debtBefore = gettersF.getBorrowDetails(posA, token);

        // Whale spikes utilization in the SAME block (no further time passes):
        // ~0% -> ~70%, which on the kink curve lifts the spot rate 20% -> ~46%.
        depositCollateralFor(whaleB, address(token1), 1_000 ether); // $1.5M collateral
        vm.prank(whaleB);
        protocolF.borrow(token, 700_000e6);

        uint256 debtAfter = gettersF.getBorrowDetails(posA, token);

        // Fixed APR: A's debt depends only on principal + elapsed time, never on
        // whoever else is borrowing. Pre-fix debtAfter jumped above debtBefore.
        assertEq(debtAfter, debtBefore, "existing borrower's debt must not move with utilization");
    }
}
