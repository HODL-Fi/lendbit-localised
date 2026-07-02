// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {MockAavePool} from "../../contracts/mocks/MockAavePool.sol";
import {Base} from "../Base.t.sol";
import "../../contracts/models/Error.sol";

/// @notice Delegated guardian (pause-only) role. A guardian can PAUSE markets,
///         vaults, and yield for fast emergency response, but can never UNPAUSE /
///         resume — that stays council-only (asymmetric pause pattern).
contract GuardianRoleTest is Base {
    address guardian = mkaddr("guardian");

    function setUp() public override {
        super.setUp();
        createVaultAndFund(1_000e6); // token4 vault, supported
    }

    // Only the council can grant/revoke the guardian capability.
    function test_only_council_can_set_guardian() public {
        vm.prank(nonAdmin);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        vaultManagerF.setGuardian(guardian, true);

        vaultManagerF.setGuardian(guardian, true);
        assertTrue(vaultManagerF.isGuardian(guardian));
        vaultManagerF.setGuardian(guardian, false);
        assertFalse(vaultManagerF.isGuardian(guardian));
    }

    // A non-guardian, non-council caller cannot pause.
    function test_non_guardian_cannot_pause() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(NOT_GUARDIAN.selector, nonAdmin));
        vaultManagerF.pauseTokenSupport(address(token4));
    }

    // Guardian can pause token support; only the council can resume.
    function test_guardian_pauses_support_council_resumes() public {
        vaultManagerF.setGuardian(guardian, true);

        vm.prank(guardian);
        vaultManagerF.pauseTokenSupport(address(token4));
        assertFalse(gettersF.tokenIsSupported(address(token4)), "paused by guardian");

        // Guardian cannot resume.
        vm.prank(guardian);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        vaultManagerF.resumeTokenSupport(address(token4));

        // Council resumes.
        vaultManagerF.resumeTokenSupport(address(token4));
        assertTrue(gettersF.tokenIsSupported(address(token4)), "resumed by council");
    }

    // Guardian can pause a vault (direction=true) but not un-pause it (direction=false).
    function test_guardian_pauses_vault_but_not_unpause() public {
        vaultManagerF.setGuardian(guardian, true);

        vm.prank(guardian);
        vaultManagerF.setVaultPaused(address(token4), true); // pause OK

        vm.prank(guardian);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        vaultManagerF.setVaultPaused(address(token4), false); // un-pause blocked

        vaultManagerF.setVaultPaused(address(token4), false); // council un-pauses
    }

    // Same asymmetry for the yield strategy pause.
    function test_guardian_pauses_yield_but_not_unpause() public {
        MockAavePool _pool = new MockAavePool(address(token1), token1.decimals());
        yieldStrategyF.configureYieldToken(address(token1), address(_pool), address(_pool.aToken()), 4000, 1500);

        vaultManagerF.setGuardian(guardian, true);

        vm.prank(guardian);
        yieldStrategyF.setYieldPause(address(token1), true); // pause OK

        vm.prank(guardian);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        yieldStrategyF.setYieldPause(address(token1), false); // un-pause blocked

        yieldStrategyF.setYieldPause(address(token1), false); // council un-pauses
    }
}
