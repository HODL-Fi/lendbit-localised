// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";

/// @notice Finding #9: bad-debt write-off and emergency pause are now reachable
///         from a facet (security council), so losses can be socialized and
///         deposits halted in an emergency.
contract BadDebtAndPauseTest is Base {
    function _setup() internal returns (TokenVault vault) {
        createVaultAndFund(10_000e6); // LP = address(this)
        vault = TokenVault(gettersF.getTokenVault(address(token4)));
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        protocolF.takeLoan(address(token4), 4_000e6, 365 days); // vault.totalBorrows = 4,000
    }

    /// @dev Writing off unrecoverable principal lowers totalAssets / share price,
    ///      socializing the loss across LPs (previously unreachable → first LP out
    ///      was made whole at later LPs' expense).
    function test_bad_debt_write_off_socializes_loss() public {
        TokenVault vault = _setup();

        uint256 assetsBefore = vault.totalAssets();
        uint256 shareValueBefore = vault.convertToAssets(1e6);

        // council writes off 1,000 of unrecoverable principal
        vaultManagerF.writeOffBadDebt(address(token4), 1_000e6);

        assertEq(vault.totalAssets(), assetsBefore - 1_000e6, "loss removed from totalAssets");
        assertLt(vault.convertToAssets(1e6), shareValueBefore, "share price fell -> loss socialized to all LPs");
    }

    /// @dev Emergency pause now actually halts deposits.
    function test_emergency_pause_halts_deposits() public {
        _setup();

        vaultManagerF.setVaultPaused(address(token4), true);

        token4.mint(user2, 1_000e6);
        vm.startPrank(user2);
        token4.approve(address(diamond), 1_000e6);
        vm.expectRevert(TokenVault.VaultPaused.selector);
        vaultManagerF.deposit(address(token4), 1_000e6);
        vm.stopPrank();

        // and resume restores deposits
        vaultManagerF.setVaultPaused(address(token4), false);
        vm.startPrank(user2);
        vaultManagerF.deposit(address(token4), 1_000e6);
        vm.stopPrank();
        assertGt(vault_balance(), 0);
    }

    function vault_balance() internal view returns (uint256) {
        return TokenVault(gettersF.getTokenVault(address(token4))).balanceOf(user2);
    }
}
