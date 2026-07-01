// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";

/// @notice Finding #3: the un-overridden ERC4626 `redeem` lets a shareholder exit
///         the vault directly, bypassing the diamond's `config.totalDeposits`
///         accounting (which drives the borrow cap and interest model).
contract DirectRedeemBypassTest is Base {
    function test_direct_redeem_desyncs_totalDeposits() public {
        createVaultAndFund(0);
        TokenVault vault = TokenVault(gettersF.getTokenVault(address(token4)));

        // user1 deposits 1,000 through the diamond → totalDeposits tracks it
        token4.mint(user1, 1_000e6);
        vm.startPrank(user1);
        token4.approve(address(diamond), 1_000e6);
        vaultManagerF.deposit(address(token4), 1_000e6);

        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).totalDeposits, 1_000e6);
        uint256 shares = vault.balanceOf(user1);

        // After the fix: a direct redeem (bypassing the diamond) reverts —
        // mint/redeem are now onlyDiamond, so the accounting can't be bypassed.
        vm.expectRevert(TokenVault.OnlyDiamond.selector);
        vault.redeem(shares, user1, user1);
        vm.stopPrank();

        // the deposit accounting stays correct; the only exit path is the
        // diamond's withdraw, which maintains config.totalDeposits.
        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).totalDeposits, 1_000e6);
        assertEq(vault.balanceOf(user1), shares, "shares intact");
    }
}
