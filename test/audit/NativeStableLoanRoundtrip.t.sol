// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {console} from "forge-std/console.sol";

/// @notice End-to-end sanity check: collateralize the native token AND a stable
///         token, take a 3-month fixed-term loan, repay it in full, and confirm the
///         borrow accounting (diamond-side config.totalBorrows AND vault.totalBorrow)
///         returns cleanly to zero.
contract NativeStableLoanRoundtripTest is Base {
    function setUp() public override {
        super.setUp();
    }

    function test_native_plus_stable_collateral_3month_loan_roundtrip() public {
        // ── Liquidity: deploy the token4 vault ($250, 6dp) and fund it with LP cash.
        createVaultAndFund(1_000_000e6);

        // Add token3 ($1, 6dp) as a stable collateral (deployed in Base, not yet listed).
        protocolF.addCollateralToken(address(token3), pricefeed3, baseTokenLTV); // LTV 8000

        // ── Collateral: 10 native @ $1,500 = $15,000  +  5,000 stable @ $1 = $5,000.
        uint256 _pid = depositCollateralFor(user1, address(1), 10 ether); // native
        depositCollateralFor(user1, address(token3), 5_000e6); // stable
        // Total $20,000 collateral, LTV 80% → $16,000 borrowable.

        // ── 3-month fixed-term loan of $10,000 (40 token4 @ $250).
        uint256 _principal = 40e6;
        vm.prank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _principal, 90 days);

        // Borrow tallies after origination.
        (, uint256 _vaultBorrowAfter) = vaultManagerF.getTokenVaultDetails(address(token4));
        uint256 _cfgBorrowAfter = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        console.log("principal borrowed        :", _principal);
        console.log("config.totalBorrows after :", _cfgBorrowAfter);
        console.log("vault.totalBorrow  after  :", _vaultBorrowAfter);
        assertEq(_cfgBorrowAfter, _principal, "config borrows == principal after loan");
        assertEq(_vaultBorrowAfter, _principal, "vault borrows == principal after loan");

        // ── Let 3 months pass (to maturity, no penalty), then read the exact debt.
        vm.warp(block.timestamp + 90 days);
        updatePricefeedsData(); // keep feeds fresh
        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId);
        console.log("outstanding debt @ 90 days:", _debt); // principal + 20% APR * 0.25y

        // ── Repay in full.
        token4.mint(user1, _debt);
        vm.startPrank(user1);
        token4.approve(address(diamond), _debt);
        protocolF.repayLoan(_loanId, _debt);
        vm.stopPrank();

        // ── Borrow accounting must return to zero on both sides.
        (, uint256 _vaultBorrowEnd) = vaultManagerF.getTokenVaultDetails(address(token4));
        uint256 _cfgBorrowEnd = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        console.log("config.totalBorrows final :", _cfgBorrowEnd);
        console.log("vault.totalBorrow  final  :", _vaultBorrowEnd);

        assertEq(_cfgBorrowEnd, 0, "config.totalBorrows back to zero");
        assertEq(_vaultBorrowEnd, 0, "vault.totalBorrow back to zero");

        // Loan is closed (no longer active for the position).
        assertEq(gettersF.getUserActiveLoanIds(_pid).length, 0, "no active loans remain");
    }
}
