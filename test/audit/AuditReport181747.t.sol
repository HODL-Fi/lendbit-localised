// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import "../../contracts/models/Protocol.sol";
import "../../contracts/models/Error.sol";

/// @title AuditReport181747 — PoCs for the genuinely-new / partially-handled items
///        in `lendbit-localised-pashov-ai-audit-report-20260702-181747.md`.
/// @notice Covers #1 (blacklisted LP withdraw), #2 (zero-amount borrow), #3
///         (bad-debt utilization DENOMINATOR), and #9 (createPositionFor griefing).
///         Findings #4/#5/#6/#7/#8 are duplicates of already-dispositioned items.
contract AuditReport181747Test is Base {
    address attacker = mkaddr("griefer181747");

    function setUp() public override {
        super.setUp();
    }

    // -------------------------------------------------------------------------
    //  #1 — a blacklisted LP can no longer withdraw vault assets
    // -------------------------------------------------------------------------

    function test_blacklisted_lp_cannot_withdraw() public {
        createVaultAndFund(0); // deploy token4 vault

        // user1 deposits as an LP while whitelisted.
        token4.mint(user1, 1000e6);
        vm.startPrank(user1);
        token4.approve(address(diamond), 1000e6);
        vaultManagerF.deposit(address(token4), 1000e6);
        vm.stopPrank();

        // Council blacklists user1.
        positionManagerF.blacklistAddress(user1);

        // Withdrawal is now frozen for the blacklisted user (pre-fix: succeeds).
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, user1));
        vaultManagerF.withdraw(address(token4), 400e6);
    }

    // -------------------------------------------------------------------------
    //  #2 — zero-amount open-ended borrow is rejected (no anchor-reset no-op)
    // -------------------------------------------------------------------------

    function test_zero_amount_borrow_reverts() public {
        createVaultAndFund(1_000_000e6);
        depositCollateralFor(user1, address(token1), 10 ether);

        vm.startPrank(user1);
        protocolF.borrow(address(token4), 10e6); // a real borrow first
        // A zero borrow (which would just reset the interest anchor) now reverts.
        vm.expectRevert(AMOUNT_ZERO.selector);
        protocolF.borrow(address(token4), 0);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    //  #3 — bad-debt writeoff also shrinks the utilization DENOMINATOR
    // -------------------------------------------------------------------------

    function test_writeOffBadDebt_reduces_totalDeposits() public {
        createVaultAndFund(1_000_000e6); // totalDeposits = 1_000_000e6

        depositCollateralFor(user1, address(token1), 100 ether);
        uint256 _borrow = 100e6; // $25k
        vm.prank(user1);
        protocolF.borrow(address(token4), _borrow);

        VaultConfiguration memory _before = vaultManagerF.getTokenVaultConfig(address(token4));

        uint256 _badDebt = 40e6; // principal loss
        vaultManagerF.writeOffBadDebt(address(token4), _badDebt);

        VaultConfiguration memory _after = vaultManagerF.getTokenVaultConfig(address(token4));

        // Numerator (prior fix) AND denominator (this fix) both drop by the principal loss.
        assertEq(_after.totalBorrows, _before.totalBorrows - _badDebt, "borrows drop (numerator)");
        assertEq(_after.totalDeposits, _before.totalDeposits - _badDebt, "deposits drop (denominator)");
    }

    // -------------------------------------------------------------------------
    //  #9 — createPositionFor is restricted to self or the security council
    // -------------------------------------------------------------------------

    function test_createPositionFor_rejects_arbitrary_caller() public {
        // A random caller cannot pre-create a position for a whitelisted victim.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(UNAUTHORIZED_POSITION_CREATION.selector, attacker));
        positionManagerF.createPositionFor(user1);
    }

    function test_createPositionFor_allows_self_and_council() public {
        // Self-service: the user creates their own position.
        vm.prank(user1);
        uint256 _self = positionManagerF.createPositionFor(user1);
        assertGt(_self, 0, "self-created position");

        // Council-run onboarding (test contract is the diamond owner).
        uint256 _byCouncil = positionManagerF.createPositionFor(user2);
        assertGt(_byCouncil, 0, "council-created position");
    }
}
