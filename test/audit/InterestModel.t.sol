// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";

/// @notice Validates the time-weighted accrual model (#4) + the protocol reserve.
contract InterestModelTest is Base {
    function _vault() internal view returns (TokenVault) {
        return TokenVault(gettersF.getTokenVault(address(token4)));
    }

    function _borrow(uint256 principal) internal returns (uint256 loanId) {
        depositCollateralFor(user1, address(token1), 1_000 ether); // ample collateral
        vm.prank(user1);
        loanId = protocolF.takeLoan(address(token4), principal, 365 days);
    }

    /// @dev A depositor who joins AFTER interest has accrued does not capture any
    ///      of the pre-deposit interest, and a repayment causes no share-price
    ///      jump to front-run (no JIT). Share value is time-weighted.
    function test_late_lp_does_not_capture_past_interest() public {
        createVaultAndFund(10_000e6); // LP1 = address(this) deposits 1,000,000
        TokenVault vault = _vault();

        uint256 loanId = _borrow(4_000e6); // 4000 token ($1M) borrowed at 20% APR

        // 6 months pass: interest accrues smoothly into the share price
        vm.warp(block.timestamp + 365 days / 2);
        updatePricefeedsData();
        assertGt(vault.convertToAssets(1e6), 1e6, "share price rose with accrual");

        // LP2 deposits AFTER the accrual — buys in at the higher price
        token4.mint(user2, 2_000e6);
        vm.startPrank(user2);
        token4.approve(address(diamond), 2_000e6);
        vaultManagerF.deposit(address(token4), 2_000e6);
        uint256 lp2Shares = vault.balanceOf(user2);
        vm.stopPrank();

        // LP2's immediately-redeemable value == their deposit (no windfall from
        // interest accrued before they joined)
        assertApproxEqAbs(vault.convertToAssets(lp2Shares), 2_000e6, 1, "late LP captured past interest");

        // borrower repays in full immediately — NO jump for LP2 to front-run
        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        token4.mint(user1, debt);
        vm.startPrank(user1);
        token4.approve(address(diamond), debt);
        protocolF.repayLoan(loanId, debt);
        vm.stopPrank();

        // LP2 still ~ their deposit (the JIT deposit-before-repay earns nothing)
        assertApproxEqAbs(vault.convertToAssets(lp2Shares), 2_000e6, 1e6, "JIT depositor profited from repayment");
    }

    /// @dev With a non-zero reserve factor, the protocol's slice of interest
    ///      accrues to a claimable reserve; LPs earn the rest; harvest pays out.
    function test_reserve_cut_and_harvest() public {
        createVaultAndFund(10_000e6);
        TokenVault vault = _vault();
        vaultManagerF.setReserveFactor(address(token4), 2000); // 20% to protocol

        uint256 loanId = _borrow(4_000e6);

        vm.warp(block.timestamp + 365 days); // 1 year → ~100,000 gross interest (20% of 500k)
        updatePricefeedsData();

        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        uint256 interest = debt - 4_000e6;
        token4.mint(user1, debt);
        vm.startPrank(user1);
        token4.approve(address(diamond), debt);
        protocolF.repayLoan(loanId, debt);
        vm.stopPrank();

        // protocol reserve == 20% of the interest paid
        uint256 expectedReserve = (interest * 2000) / 10000;
        assertEq(vaultManagerF.getVaultReserve(address(token4)), expectedReserve, "reserve = reserveFactor x interest");

        // harvest pays the reserve to a recipient and zeroes it
        address treasury = makeAddr("treasury");
        uint256 harvested = vaultManagerF.harvestVaultReserve(address(token4), treasury, type(uint256).max);
        assertEq(harvested, expectedReserve);
        assertEq(token4.balanceOf(treasury), expectedReserve);
        assertEq(vaultManagerF.getVaultReserve(address(token4)), 0);
    }
}