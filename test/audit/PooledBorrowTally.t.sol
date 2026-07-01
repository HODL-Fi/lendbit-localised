// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

/// @notice Investigates the POOLED leg: does `_repayStateChanges` under-count
///         `config.totalBorrows`, and does the same happen to the vault's own
///         `totalBorrow()` (which would make a `config >= vault` invariant
///         unable to detect either)?
contract PooledBorrowTallyTest is Base {
    function _depositAndBorrow(address user, uint256 collateral, uint256 amount) internal {
        token1.mint(user, collateral);
        vm.startPrank(user);
        token1.approve(address(diamond), collateral);
        protocolF.depositCollateral(address(token1), collateral);
        protocolF.borrow(address(token4), amount);
        vm.stopPrank();
    }

    function test_pooled_repay_undercounts_and_vault_matches() public {
        createVaultAndFund(10_000_000e18);
        protocolF.setInterestRate(5000, 5000);

        uint256 A = 1_000e6; // principal each
        _depositAndBorrow(user1, 1_000 ether, A);
        _depositAndBorrow(user2, 1_000 ether, A);

        uint256 config0 = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        (, uint256 vault0) = vaultManagerF.getTokenVaultDetails(address(token4));
        emit log_named_uint("config after 2 borrows", config0);
        emit log_named_uint("vault  after 2 borrows", vault0);

        // interest accrues on both positions
        vm.warp(block.timestamp + 200 days);
        MockV3Aggregator(pricefeed1).updateAnswer(1500 * 1e8);
        MockV3Aggregator(pricefeed4).updateAnswer(250 * 1e8);

        // user1 repays its full debt (principal + interest)
        uint256 debt1 = gettersF.getBorrowDetails(positionManagerF.getPositionIdForUser(user1), address(token4));
        emit log_named_uint("user1 debt repaid (principal + interest)", debt1);
        token4.mint(user1, debt1);
        vm.startPrank(user1);
        token4.approve(address(diamond), debt1);
        protocolF.repay(address(token4), debt1);
        vm.stopPrank();

        uint256 config1 = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        (, uint256 vault1) = vaultManagerF.getTokenVaultDetails(address(token4));
        emit log_named_uint("config after user1 full repay", config1);
        emit log_named_uint("vault  after user1 full repay", vault1);
        emit log_named_uint("true outstanding principal (user2)", A);

        // (1) FIXED: config.totalBorrows now tracks principal (s_positionPrincipal),
        //     so liquidating/repaying interest no longer eats into other borrowers'
        //     principal. config == true outstanding principal.
        assertEq(config1, A, "config.totalBorrows tracks true outstanding principal (fixed)");

        // (2) RESOLVED by the cash-basis redesign: TokenVault.repay now takes an
        //     explicit (principal, protocolCut) split and reduces totalBorrows by
        //     principal only, so the vault's own tally also tracks true principal.
        assertEq(vault1, A, "vault.totalBorrow now tracks true outstanding principal");
    }
}