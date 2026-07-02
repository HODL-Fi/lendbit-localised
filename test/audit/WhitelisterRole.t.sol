// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import "../../contracts/models/Error.sol";

/// @notice Delegated whitelister role: a non-council address can be granted the
///         ability to WHITELIST users (automated onboarding) but never to blacklist
///         (which stays council-only because it freezes user funds).
contract WhitelisterRoleTest is Base {
    address whitelister = mkaddr("whitelister");
    address brandNewUser = mkaddr("brandNewUser"); // not whitelisted in Base

    function setUp() public override {
        super.setUp();
    }

    // Only the council can grant/revoke the whitelister capability.
    function test_only_council_can_set_whitelister() public {
        vm.prank(nonAdmin);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        positionManagerF.setWhitelister(whitelister, true);

        // Council can, and the getter reflects it.
        positionManagerF.setWhitelister(whitelister, true);
        assertTrue(positionManagerF.isWhitelister(whitelister));

        positionManagerF.setWhitelister(whitelister, false);
        assertFalse(positionManagerF.isWhitelister(whitelister));
    }

    // A delegated whitelister can add users to the whitelist (behaviourally: the
    // whitelisted user can then self-create a position, which requires whitelist).
    function test_whitelister_can_whitelist() public {
        positionManagerF.setWhitelister(whitelister, true);

        vm.prank(whitelister);
        positionManagerF.whitelistAddress(brandNewUser);

        vm.prank(brandNewUser);
        uint256 _pid = positionManagerF.createPositionFor(brandNewUser);
        assertGt(_pid, 0, "whitelisted user can now act");
    }

    // A non-whitelister, non-council caller cannot whitelist.
    function test_non_whitelister_cannot_whitelist() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(NOT_WHITELISTER.selector, nonAdmin));
        positionManagerF.whitelistAddress(brandNewUser);
    }

    // A whitelister CANNOT blacklist — that stays council-only.
    function test_whitelister_cannot_blacklist() public {
        positionManagerF.setWhitelister(whitelister, true);

        vm.prank(whitelister);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        positionManagerF.blacklistAddress(user1);
    }

    // The council retains both capabilities.
    function test_council_retains_both() public {
        positionManagerF.whitelistAddress(brandNewUser); // council whitelists
        positionManagerF.blacklistAddress(brandNewUser); // council blacklists

        // Now blacklisted: cannot self-create a position.
        vm.prank(brandNewUser);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, brandNewUser));
        positionManagerF.createPositionFor(brandNewUser);
    }
}
