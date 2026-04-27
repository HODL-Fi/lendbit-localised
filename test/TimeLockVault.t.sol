// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

import {Base} from "./Base.t.sol";
import {TimeLockVault} from "../contracts/TimeLockVault.sol";
import {TokenVault} from "../contracts/TokenVault.sol";
import {VaultConfiguration} from "../contracts/models/Protocol.sol";

/**
 * @title  TimeLockVaultTest
 * @notice Foundry test suite for TimeLockVault.sol
 *
 * Test categories
 * ───────────────
 * [Constructor]       constructor reverts & storage initialisation
 * [Deposit]           happy path, share accounting, custom-error reverts
 * [Withdraw]          post-expiry happy path, yield capture, revert cases
 * [EarlyWithdraw]     penalty splitting, pre-expiry enforcement, double-withdraw
 * [Views]             getPosition, getUserLockIds, getRedeemableAssets, totalLocks
 * [Admin]             setPenaltyBps, setMinLockDuration, onlyOwner guards
 */
contract TimeLockVaultTest is Base {
    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    TimeLockVault timeLock;
    address tlOwner;

    uint16 constant INITIAL_PENALTY_BPS = 500; // 5 %
    uint256 constant MIN_LOCK = 1 days;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant LOCK_DURATION = 7 days;

    TokenVault tokenVault1;

    // -----------------------------------------------------------------------
    // Setup
    // -----------------------------------------------------------------------

    function setUp() public override {
        super.setUp();

        tlOwner = mkaddr("tlOwner");

        // Deploy a token vault for token1 through the protocol
        tokenVault1 = TokenVault(
            payable(vaultManagerF.deployVault(address(token1), pricefeed1, "Hodl Dai", "HDAI", defaultConfig))
        );

        // Whitelist timeLock after deployment (set address before construction)
        // We deploy TimeLockVault and then whitelist it
        timeLock = new TimeLockVault(address(diamond), INITIAL_PENALTY_BPS, MIN_LOCK, tlOwner);

        // Whitelist the TimeLockVault contract in the protocol so it can create a position
        positionManagerF.whitelistAddress(address(timeLock));
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// Mint tokens to `_user` and approve `timeLock` to spend them
    function _fundAndApprove(address _user, uint256 _amount) internal {
        token1.mint(_user, _amount);
        vm.prank(_user);
        token1.approve(address(timeLock), _amount);
    }

    /// Perform a full deposit as `_user` and return the lockId
    function _deposit(address _user, uint256 _amount, uint256 _lockDuration) internal returns (uint256 lockId) {
        _fundAndApprove(_user, _amount);
        vm.prank(_user);
        lockId = timeLock.deposit(address(token1), _amount, _lockDuration);
    }

    // -----------------------------------------------------------------------
    // Constructor Tests
    // -----------------------------------------------------------------------

    function testConstructor_StoredValues() public view {
        assertEq(timeLock.diamond(), address(diamond));
        assertEq(timeLock.penaltyBps(), INITIAL_PENALTY_BPS);
        assertEq(timeLock.minLockDuration(), MIN_LOCK);
        assertEq(timeLock.owner(), tlOwner);
    }

    function testConstructor_RevertZeroDiamond() public {
        vm.expectRevert(TimeLockVault.InvalidToken.selector);
        new TimeLockVault(address(0), INITIAL_PENALTY_BPS, MIN_LOCK, tlOwner);
    }

    function testConstructor_RevertPenaltyTooHigh() public {
        uint16 badPenalty = 3001; // 30.01 % — exceeds MAX_PENALTY_BPS
        vm.expectRevert(
            abi.encodeWithSelector(TimeLockVault.PenaltyTooHigh.selector, badPenalty, timeLock.MAX_PENALTY_BPS())
        );
        new TimeLockVault(address(diamond), badPenalty, MIN_LOCK, tlOwner);
    }

    function testConstructor_RevertZeroMinDuration() public {
        vm.expectRevert(TimeLockVault.ZeroDurationNotAllowed.selector);
        new TimeLockVault(address(diamond), INITIAL_PENALTY_BPS, 0, tlOwner);
    }

    // -----------------------------------------------------------------------
    // Deposit Tests
    // -----------------------------------------------------------------------

    function testDeposit_HappyPath() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        TimeLockVault.LockPosition memory pos = timeLock.getPosition(lockId);

        assertEq(lockId, 1, "first lockId should be 1");
        assertEq(pos.owner, user1, "owner mismatch");
        assertEq(pos.token, address(token1), "token mismatch");
        assertEq(pos.assets, DEPOSIT_AMOUNT, "assets mismatch");
        assertEq(pos.lockExpiry, block.timestamp + LOCK_DURATION, "expiry mismatch");
        assertFalse(pos.withdrawn, "should not be withdrawn yet");
        assertGt(pos.shares, 0, "shares should be > 0");
    }

    function testDeposit_SharesHeldByTimeLock() public {
        _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        // The vault shares must sit in the TimeLockVault, NOT user1
        uint256 timeLockShares = tokenVault1.balanceOf(address(timeLock));
        uint256 user1Shares = tokenVault1.balanceOf(user1);

        assertGt(timeLockShares, 0, "timeLock must hold shares");
        assertEq(user1Shares, 0, "user1 must hold no shares");
    }

    function testDeposit_TokensTransferredToVault() public {
        uint256 vaultBalanceBefore = token1.balanceOf(address(tokenVault1));
        _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        uint256 vaultBalanceAfter = token1.balanceOf(address(tokenVault1));

        assertEq(vaultBalanceAfter - vaultBalanceBefore, DEPOSIT_AMOUNT);
    }

    function testDeposit_EmitsLockedEvent() public {
        _fundAndApprove(user1, DEPOSIT_AMOUNT);
        uint256 expectedExpiry = block.timestamp + LOCK_DURATION;

        // We verify the event after deposit; share count is impractical to predict exactly, so we only check indexed fields
        vm.prank(user1);
        vm.expectEmit(true, true, true, false); // check topics 1-3, skip data
        emit TimeLockVault.Locked(user1, address(token1), 1, DEPOSIT_AMOUNT, 0, expectedExpiry);
        timeLock.deposit(address(token1), DEPOSIT_AMOUNT, LOCK_DURATION);
    }

    function testDeposit_MultiplePositions_SameUser() public {
        uint256 lockId1 = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        uint256 lockId2 = _deposit(user1, DEPOSIT_AMOUNT, 2 * LOCK_DURATION);

        assertEq(lockId1, 1);
        assertEq(lockId2, 2);
        assertEq(timeLock.getUserLockIds(user1).length, 2);
    }

    function testDeposit_MultiplePositions_DifferentUsers() public {
        uint256 lockId1 = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        uint256 lockId2 = _deposit(user2, DEPOSIT_AMOUNT, LOCK_DURATION);

        assertEq(lockId1, 1);
        assertEq(lockId2, 2);
        assertEq(timeLock.getUserLockIds(user1).length, 1);
        assertEq(timeLock.getUserLockIds(user2).length, 1);
        assertEq(timeLock.totalLocks(), 2);
    }

    function testDeposit_RevertZeroToken() public {
        vm.expectRevert(TimeLockVault.InvalidToken.selector);
        vm.prank(user1);
        timeLock.deposit(address(0), DEPOSIT_AMOUNT, LOCK_DURATION);
    }

    function testDeposit_RevertZeroAmount() public {
        vm.expectRevert(TimeLockVault.InvalidAmount.selector);
        vm.prank(user1);
        timeLock.deposit(address(token1), 0, LOCK_DURATION);
    }

    function testDeposit_RevertLockDurationBelowMinimum() public {
        uint256 badDuration = MIN_LOCK - 1;
        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.InvalidLockDuration.selector, badDuration, MIN_LOCK));
        vm.prank(user1);
        timeLock.deposit(address(token1), DEPOSIT_AMOUNT, badDuration);
    }

    function testDeposit_AllowsExactMinimumDuration() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, MIN_LOCK);
        assertEq(lockId, 1);
    }

    // -----------------------------------------------------------------------
    // Withdraw (post-expiry) Tests
    // -----------------------------------------------------------------------

    function testWithdraw_HappyPath() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        // Fast-forward past lock expiry
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        uint256 balanceBefore = token1.balanceOf(user1);

        vm.prank(user1);
        timeLock.withdraw(lockId);

        uint256 balanceAfter = token1.balanceOf(user1);
        assertGe(balanceAfter - balanceBefore, DEPOSIT_AMOUNT, "user should receive at least deposited amount");
    }

    function testWithdraw_PositionMarkedWithdrawn() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        vm.prank(user1);
        timeLock.withdraw(lockId);

        assertTrue(timeLock.getPosition(lockId).withdrawn, "position should be marked withdrawn");
    }

    function testWithdraw_EmitsUnlockedEvent() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        vm.prank(user1);
        vm.expectEmit(true, true, true, false);
        emit TimeLockVault.Unlocked(user1, address(token1), lockId, 0, 0);
        timeLock.withdraw(lockId);
    }

    function testWithdraw_CapturesYield() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        // Simulate borrowing to generate yield: deposit extra liquidity then borrow against it
        // The yield mechanism depends on borrow activity in the vault.
        // For this test we verify that redeemable assets >= initial deposit (yield >= 0).
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        uint256 redeemable = timeLock.getRedeemableAssets(lockId);
        assertGe(redeemable, DEPOSIT_AMOUNT, "redeemable must be >= original deposit");

        uint256 balanceBefore = token1.balanceOf(user1);
        vm.prank(user1);
        timeLock.withdraw(lockId);

        assertGe(token1.balanceOf(user1) - balanceBefore, DEPOSIT_AMOUNT);
    }

    function testWithdraw_RevertBeforeExpiry() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        uint256 expiry = block.timestamp + LOCK_DURATION;
        vm.warp(block.timestamp + LOCK_DURATION - 1); // one second before expiry

        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.LockNotExpired.selector, lockId, expiry, block.timestamp));
        vm.prank(user1);
        timeLock.withdraw(lockId);
    }

    function testWithdraw_RevertNonOwner() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.NotLockOwner.selector, lockId, user2));
        vm.prank(user2);
        timeLock.withdraw(lockId);
    }

    function testWithdraw_RevertDoubleWithdraw() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        vm.startPrank(user1);
        timeLock.withdraw(lockId);

        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.AlreadyWithdrawn.selector, lockId));
        timeLock.withdraw(lockId);
        vm.stopPrank();
    }

    function testWithdraw_RevertNonExistentLock() public {
        uint256 fakeLockId = 999;
        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.NotLockOwner.selector, fakeLockId, user1));
        vm.prank(user1);
        timeLock.withdraw(fakeLockId);
    }

    // -----------------------------------------------------------------------
    // Early Withdraw Tests
    // -----------------------------------------------------------------------

    function testEarlyWithdraw_HappyPath() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        // Warp to somewhere in the middle of the lock period
        vm.warp(block.timestamp + LOCK_DURATION / 2);

        uint256 redeemable = timeLock.getRedeemableAssets(lockId);
        uint256 expectedPenalty = (redeemable * INITIAL_PENALTY_BPS) / 10_000;
        uint256 expectedUserAmount = redeemable - expectedPenalty;

        uint256 userBalanceBefore = token1.balanceOf(user1);
        uint256 ownerBalanceBefore = token1.balanceOf(tlOwner);

        vm.prank(user1);
        timeLock.earlyWithdraw(lockId);

        uint256 userReceived = token1.balanceOf(user1) - userBalanceBefore;
        uint256 ownerReceived = token1.balanceOf(tlOwner) - ownerBalanceBefore;

        assertEq(userReceived, expectedUserAmount, "user net amount mismatch");
        assertEq(ownerReceived, expectedPenalty, "owner penalty mismatch");
    }

    function testEarlyWithdraw_PenaltyGoesToOwner() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        uint256 ownerBalanceBefore = token1.balanceOf(tlOwner);

        vm.prank(user1);
        timeLock.earlyWithdraw(lockId);

        assertGt(token1.balanceOf(tlOwner) - ownerBalanceBefore, 0, "owner should receive a penalty");
    }

    function testEarlyWithdraw_PositionMarkedWithdrawn() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        vm.prank(user1);
        timeLock.earlyWithdraw(lockId);

        assertTrue(timeLock.getPosition(lockId).withdrawn);
    }

    function testEarlyWithdraw_EmitsEarlyUnlockedEvent() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        vm.prank(user1);
        vm.expectEmit(true, true, true, false);
        emit TimeLockVault.EarlyUnlocked(user1, address(token1), lockId, 0, 0, 0);
        timeLock.earlyWithdraw(lockId);
    }

    function testEarlyWithdraw_AfterExpiryStillWorks() public {
        // earlyWithdraw should function even after the lock has expired
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        // Should succeed but still apply penalty
        uint256 ownerBalanceBefore = token1.balanceOf(tlOwner);
        vm.prank(user1);
        timeLock.earlyWithdraw(lockId);
        assertGt(token1.balanceOf(tlOwner) - ownerBalanceBefore, 0);
    }

    function testEarlyWithdraw_RevertNonOwner() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.NotLockOwner.selector, lockId, user2));
        vm.prank(user2);
        timeLock.earlyWithdraw(lockId);
    }

    function testEarlyWithdraw_RevertDoubleWithdraw() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        vm.startPrank(user1);
        timeLock.earlyWithdraw(lockId);

        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.AlreadyWithdrawn.selector, lockId));
        timeLock.earlyWithdraw(lockId);
        vm.stopPrank();
    }

    function testEarlyWithdraw_CannotDoubleWithdrawAcrossMethods() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.warp(block.timestamp + LOCK_DURATION + 1);

        vm.startPrank(user1);
        // First withdraw via normal path
        timeLock.withdraw(lockId);

        // Then try earlyWithdraw — should revert
        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.AlreadyWithdrawn.selector, lockId));
        timeLock.earlyWithdraw(lockId);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // View Function Tests
    // -----------------------------------------------------------------------

    function testGetPosition_ReturnsCorrectData() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        TimeLockVault.LockPosition memory pos = timeLock.getPosition(lockId);

        assertEq(pos.owner, user1);
        assertEq(pos.token, address(token1));
        assertEq(pos.assets, DEPOSIT_AMOUNT);
        assertEq(pos.lockExpiry, block.timestamp + LOCK_DURATION);
        assertFalse(pos.withdrawn);
    }

    function testGetUserLockIds_ReturnsAllIds() public {
        _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        _deposit(user1, DEPOSIT_AMOUNT, 2 * LOCK_DURATION);
        _deposit(user2, DEPOSIT_AMOUNT, LOCK_DURATION);

        uint256[] memory user1Ids = timeLock.getUserLockIds(user1);
        uint256[] memory user2Ids = timeLock.getUserLockIds(user2);

        assertEq(user1Ids.length, 2);
        assertEq(user2Ids.length, 1);
        assertEq(user1Ids[0], 1);
        assertEq(user1Ids[1], 2);
        assertEq(user2Ids[0], 3);
    }

    function testGetUserLockIds_EmptyForNewUser() public view {
        uint256[] memory ids = timeLock.getUserLockIds(address(0xBEEF));
        assertEq(ids.length, 0);
    }

    function testGetRedeemableAssets_MatchesShares() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        // At deposit time (no yield yet), redeemable ≈ DEPOSIT_AMOUNT
        uint256 redeemable = timeLock.getRedeemableAssets(lockId);
        assertApproxEqAbs(redeemable, DEPOSIT_AMOUNT, 1, "redeemable should approximate deposit amount");
    }

    function testGetRedeemableAssets_ZeroForWithdrawnPosition() public {
        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.warp(block.timestamp + LOCK_DURATION + 1);
        vm.prank(user1);
        timeLock.withdraw(lockId);

        assertEq(timeLock.getRedeemableAssets(lockId), 0, "should return 0 for withdrawn position");
    }

    function testGetRedeemableAssets_ZeroForNonExistentLock() public view {
        assertEq(timeLock.getRedeemableAssets(999), 0);
    }

    function testTotalLocks_TracksCorrectly() public {
        assertEq(timeLock.totalLocks(), 0);
        _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        assertEq(timeLock.totalLocks(), 1);
        _deposit(user2, DEPOSIT_AMOUNT, LOCK_DURATION);
        assertEq(timeLock.totalLocks(), 2);
    }

    // -----------------------------------------------------------------------
    // Admin Function Tests
    // -----------------------------------------------------------------------

    function testSetPenaltyBps_UpdatesValue() public {
        uint16 newPenalty = 1000; // 10 %
        vm.prank(tlOwner);
        timeLock.setPenaltyBps(newPenalty);
        assertEq(timeLock.penaltyBps(), newPenalty);
    }

    function testSetPenaltyBps_EmitsPenaltyUpdatedEvent() public {
        uint16 newPenalty = 1000;
        vm.expectEmit(true, true, false, false);
        emit TimeLockVault.PenaltyUpdated(INITIAL_PENALTY_BPS, newPenalty);
        vm.prank(tlOwner);
        timeLock.setPenaltyBps(newPenalty);
    }

    function testSetPenaltyBps_AllowsZero() public {
        // Zero penalty = no early-withdrawal fee, still valid
        vm.prank(tlOwner);
        timeLock.setPenaltyBps(0);
        assertEq(timeLock.penaltyBps(), 0);
    }

    function testSetPenaltyBps_RevertTooHigh() public {
        uint16 badPenalty = timeLock.MAX_PENALTY_BPS() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(TimeLockVault.PenaltyTooHigh.selector, badPenalty, timeLock.MAX_PENALTY_BPS())
        );
        vm.prank(tlOwner);
        timeLock.setPenaltyBps(badPenalty);
    }

    function testSetPenaltyBps_RevertNonOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        timeLock.setPenaltyBps(1000);
    }

    function testSetMinLockDuration_UpdatesValue() public {
        uint256 newMin = 2 days;
        vm.prank(tlOwner);
        timeLock.setMinLockDuration(newMin);
        assertEq(timeLock.minLockDuration(), newMin);
    }

    function testSetMinLockDuration_EmitsEvent() public {
        uint256 newMin = 2 days;
        vm.expectEmit(true, true, false, false);
        emit TimeLockVault.MinLockDurationUpdated(MIN_LOCK, newMin);
        vm.prank(tlOwner);
        timeLock.setMinLockDuration(newMin);
    }

    function testSetMinLockDuration_RevertZero() public {
        vm.expectRevert(TimeLockVault.ZeroDurationNotAllowed.selector);
        vm.prank(tlOwner);
        timeLock.setMinLockDuration(0);
    }

    function testSetMinLockDuration_RevertNonOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        timeLock.setMinLockDuration(2 days);
    }

    function testSetMinLockDuration_NewMinEnforcedOnNextDeposit() public {
        uint256 newMin = 14 days;
        vm.prank(tlOwner);
        timeLock.setMinLockDuration(newMin);

        // LOCK_DURATION (7 days) is now below the new minimum (14 days)
        token1.mint(user1, DEPOSIT_AMOUNT);
        vm.startPrank(user1);
        token1.approve(address(timeLock), DEPOSIT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(TimeLockVault.InvalidLockDuration.selector, LOCK_DURATION, newMin));
        timeLock.deposit(address(token1), DEPOSIT_AMOUNT, LOCK_DURATION);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Penalty Rate Effect Tests
    // -----------------------------------------------------------------------

    function testPenaltyEffect_HigherPenaltyMeansLessToUser() public {
        uint16 penalty1Bps = INITIAL_PENALTY_BPS; // 5 %
        uint16 penalty2Bps = 1000; // 10 %

        // user1 deposits at 5 % penalty
        uint256 lockId1 = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);

        uint256 lockId2 = _deposit(user2, DEPOSIT_AMOUNT, LOCK_DURATION);

        uint256 user1Before = token1.balanceOf(user1);
        uint256 user2Before = token1.balanceOf(user2);

        vm.prank(user1);
        timeLock.earlyWithdraw(lockId1);
        // Change penalty to 10 % for user2's withdrawal
        vm.prank(tlOwner);
        timeLock.setPenaltyBps(penalty2Bps);

        vm.prank(user2);
        timeLock.earlyWithdraw(lockId2);

        uint256 user1Received = token1.balanceOf(user1) - user1Before;
        uint256 user2Received = token1.balanceOf(user2) - user2Before;

        // Both deposits are DEPOSIT_AMOUNT at 1:1 exchange rate (no yield in test).
        // user1 net = DEPOSIT_AMOUNT * (1 - 5%)  = 9500e17
        // user2 net = DEPOSIT_AMOUNT * (1 - 10%) = 9000e17
        uint256 expectedUser1 = DEPOSIT_AMOUNT * (10_000 - penalty1Bps) / 10_000;
        uint256 expectedUser2 = DEPOSIT_AMOUNT * (10_000 - penalty2Bps) / 10_000;

        assertEq(user1Received, expectedUser1, "user1 net mismatch");
        assertEq(user2Received, expectedUser2, "user2 net mismatch");
        assertGt(user1Received, user2Received, "higher penalty = less to user");
    }

    function testZeroPenalty_NoOwnerCut() public {
        vm.prank(tlOwner);
        timeLock.setPenaltyBps(0);

        uint256 lockId = _deposit(user1, DEPOSIT_AMOUNT, LOCK_DURATION);
        uint256 ownerBalanceBefore = token1.balanceOf(tlOwner);

        vm.prank(user1);
        timeLock.earlyWithdraw(lockId);

        assertEq(token1.balanceOf(tlOwner), ownerBalanceBefore, "owner should receive nothing with 0 penalty");
    }
}
