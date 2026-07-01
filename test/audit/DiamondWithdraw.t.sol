// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";

/// @notice Finding #7: a diamond-mediated `withdraw` reverts on the ERC4626
///         allowance check because the vault sees `msg.sender == diamond != owner`
///         and the deposit flow never grants a user→diamond share allowance.
contract DiamondWithdrawTest is Base {
    function _deposit(address user, uint256 amount) internal {
        token4.mint(user, amount);
        vm.startPrank(user);
        token4.approve(address(diamond), amount);
        vaultManagerF.deposit(address(token4), amount);
        vm.stopPrank();
    }

    /// @dev A depositor can withdraw their own deposit through the diamond with
    ///      no separate share approval. (Pre-fix this reverted on the allowance
    ///      check — validated, then the fix makes it succeed.)
    function test_depositor_can_withdraw_without_share_approval() public {
        createVaultAndFund(0);
        _deposit(user1, 1_000e6);

        vm.prank(user1);
        vaultManagerF.withdraw(address(token4), 1_000e6);

        assertEq(token4.balanceOf(user1), 1_000e6, "user got their assets back");
    }
}
