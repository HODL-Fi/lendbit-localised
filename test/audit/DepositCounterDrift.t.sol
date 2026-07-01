// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";

/// @notice Validates finding #8: `config.totalDeposits` must track supplied
///         principal, not drift below it when an LP withdraws interest-inclusive
///         assets (which otherwise clamps it to 0 and DoSes borrowing).
contract DepositCounterDriftTest is Base {
    function test_totalDeposits_tracks_principal_not_interest() public {
        createVaultAndFund(10_000e6); // LP1 = address(this) deposits 10,000
        TokenVault vault = TokenVault(gettersF.getTokenVault(address(token4)));

        // LP2 deposits the same
        token4.mint(user2, 10_000e6);
        vm.startPrank(user2);
        token4.approve(address(diamond), 10_000e6);
        vaultManagerF.deposit(address(token4), 10_000e6);
        vm.stopPrank();
        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).totalDeposits, 20_000e6);

        // a borrower takes + fully repays a loan → interest flows into the pool
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        uint256 loanId = protocolF.takeLoan(address(token4), 4_000e6, 365 days);
        vm.warp(block.timestamp + 365 days);
        updatePricefeedsData();
        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        token4.mint(user1, debt);
        vm.startPrank(user1);
        token4.approve(address(diamond), debt);
        protocolF.repayLoan(loanId, debt);
        vm.stopPrank();

        // LP1 withdraws its FULL position (principal + earned interest).
        // (approve the diamond to spend our shares — the ERC4626 allowance path)
        uint256 lp1Assets = vault.convertToAssets(vault.balanceOf(address(this)));
        assertGt(lp1Assets, 10_000e6, "LP1 earned interest");
        vault.approve(address(diamond), type(uint256).max);
        vaultManagerF.withdraw(address(token4), lp1Assets);

        // totalDeposits now reflects LP2's principal (~10,000), NOT under-counted
        // by LP1's earned interest. Pre-fix this would be ~20,000 - 10,4xx ≈ 9,6xx.
        uint256 td = vaultManagerF.getTokenVaultConfig(address(token4)).totalDeposits;
        assertApproxEqAbs(td, 10_000e6, 1e6, "totalDeposits drifted below supplied principal (#8)");

        // and borrowing is NOT DoS'd — a fresh borrow within 80% of the (correct)
        // deposit base still validates
        depositCollateralFor(user2, address(token1), 1_000 ether);
        vm.prank(user2);
        protocolF.takeLoan(address(token4), 3_000e6, 365 days); // reverts pre-fix if td under-counted
    }
}
