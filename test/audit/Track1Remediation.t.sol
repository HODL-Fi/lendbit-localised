// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";
import "../../contracts/models/Error.sol";

/// @notice Regression tests for the Track 1 (diamond-side, upgrade-safe) remediation
///         batch: H-01 (unbounded tenure), M-05 (whitelist reverses blacklist),
///         M-07 (rebalance skips the freeze), L-10 (unbounded reserve factor).
///         The vault-side fixes (M-04, M-09, M-03) are Track 2 and not covered here.
contract Track1RemediationTest is Base {
    address whitelister = mkaddr("whitelister");
    address freshUser = mkaddr("freshUser"); // not whitelisted in Base

    // ---------------------------------------------------------------------
    // H-01 — loan tenure is bounded above so maturity cannot overflow.
    // ---------------------------------------------------------------------

    /// @dev A tenure of `type(uint256).max - block.timestamp + 1` overflows the
    ///      maturity computation. Pre-fix this bricked the loan's repay path deep in
    ///      `_outstandingBalance` (Panic 0x11); now it reverts cleanly at origination.
    function test_H01_overflowing_tenure_reverts_at_origination() public {
        createVaultAndFund(100_000e6);
        depositCollateralFor(user1, address(token1), 1_000 ether);

        uint256 maxTenure = type(uint256).max - block.timestamp;
        uint256 overflowing = maxTenure + 1;
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TENURE_TOO_LONG.selector, overflowing, maxTenure));
        protocolF.takeLoan(address(token4), 1_000e6, overflowing);
    }

    /// @dev The boundary value `type(uint256).max - block.timestamp` does NOT overflow
    ///      (maturity == type(uint256).max exactly), so it must not be rejected as
    ///      TENURE_TOO_LONG — the Description's stated trigger is not the real one.
    function test_H01_boundary_tenure_not_rejected_as_too_long() public {
        createVaultAndFund(100_000e6);
        depositCollateralFor(user1, address(token1), 1_000 ether);

        uint256 boundary = type(uint256).max - block.timestamp;
        // May still revert for other reasons (health/utilization), but NEVER with
        // TENURE_TOO_LONG at this exact value.
        vm.prank(user1);
        try protocolF.takeLoan(address(token4), 1_000e6, boundary) returns (uint256) {
            // fine — accepted
        } catch (bytes memory reason) {
            bytes4 sel;
            assembly {
                sel := mload(add(reason, 0x20))
            }
            assertTrue(sel != TENURE_TOO_LONG.selector, "boundary value wrongly rejected as too long");
        }
    }

    /// @dev Ordinary tenures are unaffected.
    function test_H01_normal_tenure_still_works() public {
        createVaultAndFund(100_000e6);
        depositCollateralFor(user1, address(token1), 1_000 ether);

        vm.prank(user1);
        uint256 loanId = protocolF.takeLoan(address(token4), 1_000e6, 365 days);
        assertGt(loanId, 0, "normal-tenure loan must still open");
    }

    // ---------------------------------------------------------------------
    // M-05 — a delegated whitelister cannot reverse a council blacklist.
    // ---------------------------------------------------------------------

    function test_M05_whitelister_cannot_reverse_council_blacklist() public {
        // Onboard freshUser, then the council blacklists them.
        positionManagerF.whitelistAddress(freshUser); // council (address(this)) whitelists
        positionManagerF.blacklistAddress(freshUser); // council blacklists -> tombstone set

        positionManagerF.setWhitelister(whitelister, true);

        // The hot-key whitelister tries to silently re-admit the blacklisted user.
        vm.prank(whitelister);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_BLACKLISTED.selector, freshUser));
        positionManagerF.whitelistAddress(freshUser);

        // Still frozen: cannot self-create a position.
        vm.prank(freshUser);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, freshUser));
        positionManagerF.createPositionFor(freshUser);
    }

    /// @dev Even the owner path (whitelistAddress as council) cannot bypass the
    ///      tombstone — re-admission requires an explicit council un-blacklist first.
    function test_M05_council_reversal_is_two_step_and_explicit() public {
        positionManagerF.whitelistAddress(freshUser);
        positionManagerF.blacklistAddress(freshUser);

        // Direct re-whitelist is blocked by the tombstone.
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_BLACKLISTED.selector, freshUser));
        positionManagerF.whitelistAddress(freshUser);

        // Council clears the tombstone, THEN whitelists — deliberate two-step.
        positionManagerF.unblacklistAddress(freshUser);
        positionManagerF.whitelistAddress(freshUser);

        vm.prank(freshUser);
        uint256 pid = positionManagerF.createPositionFor(freshUser);
        assertGt(pid, 0, "re-admitted user can act after explicit council reversal");
    }

    /// @dev Only the council can clear a tombstone.
    function test_M05_only_council_can_unblacklist() public {
        positionManagerF.blacklistAddress(freshUser);

        vm.prank(nonAdmin);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        positionManagerF.unblacklistAddress(freshUser);
    }

    // ---------------------------------------------------------------------
    // M-07 — rebalanceMyPosition honours the whitelist/blacklist freeze.
    // ---------------------------------------------------------------------

    function test_M07_blacklisted_user_cannot_rebalance() public {
        // user1 is whitelisted in Base setUp; council blacklists.
        positionManagerF.blacklistAddress(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, user1));
        yieldStrategyF.rebalanceMyPosition(address(token1));
    }

    /// @dev The guard blocks only blacklisted callers: a whitelisted caller passes the
    ///      freeze check and fails later (no position), proving parity with claimYield.
    function test_M07_whitelisted_user_passes_freeze_check() public {
        vm.prank(user1); // whitelisted, but has no yield position
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user1));
        yieldStrategyF.rebalanceMyPosition(address(token1));
    }

    // ---------------------------------------------------------------------
    // L-10 — reserve factor is bounded at vault construction.
    // ---------------------------------------------------------------------

    function test_L10_construction_rejects_out_of_range_reserve_factor() public {
        vm.expectRevert(TokenVault.InvalidRate.selector);
        new TokenVault(address(token1), "x", "xVault", address(this), 2000, 10_001);
    }

    function test_L10_construction_accepts_valid_reserve_factor() public {
        TokenVault v = new TokenVault(address(token1), "x", "xVault", address(this), 2000, 1_000);
        assertEq(v.asset(), address(token1), "valid reserve factor constructs normally");
    }
}
