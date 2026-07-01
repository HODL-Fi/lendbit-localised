// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

import {MockAavePool} from "../../contracts/mocks/MockAavePool.sol";
import {MockMismatchPool, MockRevertingPool} from "../../contracts/mocks/MockMismatchPool.sol";
import {YieldStrategyConfig, YieldPosition} from "../../contracts/models/Yield.sol";
import {Base} from "../Base.t.sol";

/// @title CovYield — Branch-coverage suite for LibYieldStrategy + YieldStrategyFacet
/// @notice Drives every reachable branch of the yield strategy: config validation,
///         pause gating, rebalance allocate/withdraw/deficit paths, claim/harvest
///         (amount selection + revert sides), accrual, and the facet access-control
///         and recipient-defaulting branches.
contract CovYieldTest is Base {
    MockAavePool internal mockPool;
    ERC20Mock internal aToken;

    uint16 internal constant ALLOCATION_BPS = 4000; // 40%
    uint16 internal constant PROTOCOL_SHARE_BPS = 1500; // 15%

    function setUp() public override {
        super.setUp();
        mockPool = new MockAavePool(address(token1), token1.decimals());
        aToken = mockPool.aToken();
        vm.label(address(mockPool), "MockAavePool");

        yieldStrategyF.configureYieldToken(
            address(token1), address(mockPool), address(aToken), ALLOCATION_BPS, PROTOCOL_SHARE_BPS
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _deposit(address _user, uint256 _amount) internal returns (uint256 positionId) {
        mintTokenTo(address(token1), _user, _amount);
        vm.startPrank(_user);
        token1.approve(address(diamond), _amount);
        protocolF.depositCollateral(address(token1), _amount);
        vm.stopPrank();
        positionId = positionManagerF.getPositionIdForUser(_user);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // configureYieldToken — validation reverts + access control + success
    // ─────────────────────────────────────────────────────────────────────────

    function test_Configure_RevertZeroToken() public {
        vm.expectRevert(abi.encodeWithSignature("ADDRESS_ZERO()"));
        yieldStrategyF.configureYieldToken(address(0), address(mockPool), address(aToken), ALLOCATION_BPS, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_RevertZeroPool() public {
        ERC20Mock fresh = new ERC20Mock(18);
        vm.expectRevert(abi.encodeWithSignature("ADDRESS_ZERO()"));
        yieldStrategyF.configureYieldToken(address(fresh), address(0), address(aToken), ALLOCATION_BPS, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_RevertZeroAToken() public {
        ERC20Mock fresh = new ERC20Mock(18);
        vm.expectRevert(abi.encodeWithSignature("ADDRESS_ZERO()"));
        yieldStrategyF.configureYieldToken(address(fresh), address(mockPool), address(0), ALLOCATION_BPS, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_RevertNativeToken() public {
        // address(1) == Constants.NATIVE_TOKEN
        vm.expectRevert(abi.encodeWithSignature("TOKEN_NOT_SUPPORTED(address)", address(1)));
        yieldStrategyF.configureYieldToken(address(1), address(mockPool), address(aToken), ALLOCATION_BPS, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_RevertAllocationTooHigh() public {
        ERC20Mock fresh = new ERC20Mock(18);
        vm.expectRevert(abi.encodeWithSignature("YIELD_ALLOCATION_TOO_HIGH(uint16)", uint16(10001)));
        yieldStrategyF.configureYieldToken(address(fresh), address(mockPool), address(aToken), 10001, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_RevertProtocolShareTooHigh() public {
        ERC20Mock fresh = new ERC20Mock(18);
        vm.expectRevert(abi.encodeWithSignature("YIELD_ALLOCATION_TOO_HIGH(uint16)", uint16(10001)));
        yieldStrategyF.configureYieldToken(address(fresh), address(mockPool), address(aToken), ALLOCATION_BPS, 10001);
    }

    function test_Configure_RevertPoolTokenMismatch() public {
        ERC20Mock fresh = new ERC20Mock(18);
        MockMismatchPool mismatch = new MockMismatchPool(address(1));
        vm.expectRevert(abi.encodeWithSignature("POOL_TOKEN_MISMATCH(address,address)", address(mismatch), address(aToken)));
        yieldStrategyF.configureYieldToken(address(fresh), address(mismatch), address(aToken), ALLOCATION_BPS, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_RevertBadPoolAddress() public {
        ERC20Mock fresh = new ERC20Mock(18);
        MockRevertingPool reverting = new MockRevertingPool();
        vm.expectRevert(abi.encodeWithSignature("BAD_POOL_ADDRESS(address)", address(reverting)));
        yieldStrategyF.configureYieldToken(address(fresh), address(reverting), address(aToken), ALLOCATION_BPS, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_RevertNotCouncil() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("ONLY_SECURITY_COUNCIL()"));
        yieldStrategyF.configureYieldToken(address(token2), address(mockPool), address(aToken), ALLOCATION_BPS, PROTOCOL_SHARE_BPS);
    }

    function test_Configure_Success() public view {
        YieldStrategyConfig memory cfg = yieldStrategyF.getYieldConfig(address(token1));
        assertTrue(cfg.enabled, "enabled");
        assertTrue(!cfg.paused, "not paused");
        assertEq(cfg.aavePool, address(mockPool), "pool");
        assertEq(cfg.aToken, address(aToken), "aToken");
        assertEq(cfg.allocationBps, ALLOCATION_BPS, "alloc");
        assertEq(cfg.protocolShareBps, PROTOCOL_SHARE_BPS, "share");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // setYieldPause — revert / access control / pause + unpause
    // ─────────────────────────────────────────────────────────────────────────

    function test_SetPause_RevertNotEnabled() public {
        // token2 was never configured for yield
        vm.expectRevert(abi.encodeWithSignature("YIELD_NOT_ENABLED(address)", address(token2)));
        yieldStrategyF.setYieldPause(address(token2), true);
    }

    function test_SetPause_RevertNotCouncil() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("ONLY_SECURITY_COUNCIL()"));
        yieldStrategyF.setYieldPause(address(token1), true);
    }

    function test_SetPause_PauseThenUnpause() public {
        yieldStrategyF.setYieldPause(address(token1), true);
        assertTrue(yieldStrategyF.getYieldConfig(address(token1)).paused, "paused");

        yieldStrategyF.setYieldPause(address(token1), false);
        assertTrue(!yieldStrategyF.getYieldConfig(address(token1)).paused, "unpaused");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // rebalanceMyPosition — facet positionId guard + lib allocate/withdraw/noop
    // ─────────────────────────────────────────────────────────────────────────

    function test_Rebalance_RevertNoPosition() public {
        vm.prank(nonAdmin); // whitelisted but no position
        vm.expectRevert(abi.encodeWithSignature("NO_POSITION_ID(address)", nonAdmin));
        yieldStrategyF.rebalanceMyPosition(address(token1));
    }

    function test_Rebalance_PausedIsNoop() public {
        // Pause first so deposit does not allocate; principal stays 0.
        yieldStrategyF.setYieldPause(address(token1), true);
        _deposit(user1, 1000 ether);

        // rebalance while paused -> _shouldProcess false -> early return, no revert, no allocation
        vm.prank(user1);
        yieldStrategyF.rebalanceMyPosition(address(token1));

        YieldPosition memory pos = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos.principal, 0, "no allocation while paused");
        assertEq(aToken.balanceOf(address(diamond)), 0, "nothing supplied to Aave");
    }

    function test_Rebalance_AllocateBranch() public {
        // Deposit while paused => principal 0, then unpause and rebalance => allocate branch.
        yieldStrategyF.setYieldPause(address(token1), true);
        _deposit(user1, 1000 ether);
        yieldStrategyF.setYieldPause(address(token1), false);

        vm.prank(user1);
        yieldStrategyF.rebalanceMyPosition(address(token1));

        uint256 expected = (1000 ether * uint256(ALLOCATION_BPS)) / 10_000;
        YieldPosition memory pos = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos.principal, expected, "allocated to target");
        assertEq(aToken.balanceOf(address(diamond)), expected, "aToken minted");
    }

    function test_Rebalance_EqualIsNoop() public {
        _deposit(user1, 1000 ether); // deposit auto-allocates to target
        uint256 principalBefore = yieldStrategyF.getYieldPosition(user1, address(token1)).principal;

        vm.prank(user1);
        yieldStrategyF.rebalanceMyPosition(address(token1)); // target == principal => neither branch

        uint256 principalAfter = yieldStrategyF.getYieldPosition(user1, address(token1)).principal;
        assertEq(principalAfter, principalBefore, "no change when already at target");
    }

    function test_Rebalance_WithdrawBranch() public {
        _deposit(user1, 1000 ether); // principal = 400
        uint256 principalBefore = yieldStrategyF.getYieldPosition(user1, address(token1)).principal;
        assertEq(principalBefore, 400 ether, "initial principal");

        // Re-configure with a lower allocation so principal now exceeds target.
        yieldStrategyF.configureYieldToken(
            address(token1), address(mockPool), address(aToken), 1000, PROTOCOL_SHARE_BPS // 10%
        );

        vm.prank(user1);
        yieldStrategyF.rebalanceMyPosition(address(token1)); // principal(400) > target(100) => withdraw branch

        uint256 expected = (1000 ether * 1000) / 10_000; // 100 ether
        YieldPosition memory pos = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos.principal, expected, "principal reduced to new target");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // claimYield — facet guards + lib revert sides + amount selection
    // ─────────────────────────────────────────────────────────────────────────

    function test_Claim_RevertNoPosition() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("NO_POSITION_ID(address)", nonAdmin));
        yieldStrategyF.claimYield(address(token1), 0, address(0));
    }

    function test_Claim_RevertNotEnabled() public {
        _deposit(user1, 1000 ether); // gives user1 a position
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("YIELD_NOT_ENABLED(address)", address(token2)));
        yieldStrategyF.claimYield(address(token2), 0, address(0));
    }

    function test_Claim_RevertPaused() public {
        _deposit(user1, 1000 ether);
        yieldStrategyF.setYieldPause(address(token1), true);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("YIELD_TOKEN_PAUSED(address)", address(token1)));
        yieldStrategyF.claimYield(address(token1), 0, address(0));
    }

    function test_Claim_RevertNothingToClaim() public {
        uint256 positionId = _deposit(user1, 1000 ether); // allocates, totalPrincipal>0, no yield
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("YIELD_NOTHING_TO_CLAIM(uint256,address)", positionId, address(token1)));
        yieldStrategyF.claimYield(address(token1), 0, address(0));
    }

    function test_Claim_RevertNothingToClaim_ZeroTotalPrincipal() public {
        // Deposit while paused -> totalPrincipal stays 0 -> exercises _accrueYield refresh branch.
        yieldStrategyF.setYieldPause(address(token1), true);
        uint256 positionId = _deposit(user1, 1000 ether);
        yieldStrategyF.setYieldPause(address(token1), false);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("YIELD_NOTHING_TO_CLAIM(uint256,address)", positionId, address(token1)));
        yieldStrategyF.claimYield(address(token1), 0, address(0));
    }

    function test_Claim_FullDefaultRecipient() public {
        _deposit(user1, 5000 ether);
        uint256 simulated = 500 ether;
        mockPool.simulateYield(address(diamond), simulated);

        uint256 expectedUserShare = simulated * (10_000 - PROTOCOL_SHARE_BPS) / 10_000;

        uint256 before = token1.balanceOf(user1);
        vm.prank(user1);
        uint256 claimed = yieldStrategyF.claimYield(address(token1), 0, address(0)); // _requested==0 => full; recipient default => msg.sender
        uint256 afterBal = token1.balanceOf(user1);

        assertEq(claimed, expectedUserShare, "claimed full user share");
        assertEq(afterBal - before, expectedUserShare, "tokens routed to caller (default recipient)");
        assertEq(yieldStrategyF.getPendingYield(address(token1)), 0, "pending cleared");
    }

    function test_Claim_PartialThenRemainderSpecificRecipient() public {
        _deposit(user1, 5000 ether);
        mockPool.simulateYield(address(diamond), 500 ether);

        vm.prank(user1);
        uint256 available = yieldStrategyF.getPendingYield(address(token1));
        assertGt(available, 0, "has pending");

        uint256 part = available / 4;
        uint256 recipientBefore = token1.balanceOf(user2);

        vm.prank(user1);
        uint256 claimed = yieldStrategyF.claimYield(address(token1), part, user2); // _requested in-range => requested; explicit recipient
        assertEq(claimed, part, "claimed requested partial");
        assertEq(token1.balanceOf(user2) - recipientBefore, part, "partial sent to explicit recipient");

        // Claim the rest with an over-request -> clamps to remaining available.
        vm.prank(user1);
        uint256 claimed2 = yieldStrategyF.claimYield(address(token1), type(uint256).max, user2);
        assertEq(claimed2, available - part, "remainder claimed via over-request clamp");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // harvestProtocolYield — access control + revert sides + amount selection
    // ─────────────────────────────────────────────────────────────────────────

    function test_Harvest_RevertNotCouncil() public {
        _deposit(user1, 1000 ether);
        mockPool.simulateYield(address(diamond), 100 ether);
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSignature("ONLY_SECURITY_COUNCIL()"));
        yieldStrategyF.harvestProtocolYield(address(token1), address(this), 0);
    }

    function test_Harvest_RevertNotEnabled() public {
        vm.expectRevert(abi.encodeWithSignature("YIELD_NOT_ENABLED(address)", address(token2)));
        yieldStrategyF.harvestProtocolYield(address(token2), address(this), 0);
    }

    function test_Harvest_RevertPaused() public {
        yieldStrategyF.setYieldPause(address(token1), true);
        vm.expectRevert(abi.encodeWithSignature("YIELD_TOKEN_PAUSED(address)", address(token1)));
        yieldStrategyF.harvestProtocolYield(address(token1), address(this), 0);
    }

    function test_Harvest_RevertNothingToClaim() public {
        _deposit(user1, 1000 ether); // no yield => protocolAccrued 0
        vm.expectRevert(abi.encodeWithSignature("YIELD_NOTHING_TO_CLAIM(uint256,address)", uint256(0), address(token1)));
        yieldStrategyF.harvestProtocolYield(address(token1), address(this), 0);
    }

    function test_Harvest_FullDefaultRecipient() public {
        _deposit(user1, 3000 ether);
        uint256 simulated = 300 ether;
        mockPool.simulateYield(address(diamond), simulated);

        uint256 expectedProtocolShare = simulated * PROTOCOL_SHARE_BPS / 10_000;
        // recipient address(0) => defaults to contract owner == address(this)
        uint256 before = token1.balanceOf(address(this));
        uint256 harvested = yieldStrategyF.harvestProtocolYield(address(token1), address(0), 0);
        uint256 afterBal = token1.balanceOf(address(this));

        assertEq(harvested, expectedProtocolShare, "harvested full protocol share");
        assertEq(afterBal - before, expectedProtocolShare, "routed to owner (default recipient)");
    }

    function test_Harvest_PartialThenOverRequest() public {
        _deposit(user1, 3000 ether);
        mockPool.simulateYield(address(diamond), 300 ether);

        uint256 expectedProtocolShare = 300 ether * uint256(PROTOCOL_SHARE_BPS) / 10_000;
        uint256 part = expectedProtocolShare / 3;

        uint256 recipientBefore = token1.balanceOf(user2);
        uint256 harvested = yieldStrategyF.harvestProtocolYield(address(token1), user2, part); // explicit recipient + in-range amount
        assertEq(harvested, part, "harvested requested partial");
        assertEq(token1.balanceOf(user2) - recipientBefore, part, "partial to explicit recipient");

        uint256 harvested2 = yieldStrategyF.harvestProtocolYield(address(token1), user2, type(uint256).max); // over-request clamp
        assertEq(harvested2, expectedProtocolShare - part, "remainder via over-request clamp");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // getPendingYield / getYieldPosition — view branches
    // ─────────────────────────────────────────────────────────────────────────

    function test_GetPending_NoPosition() public {
        vm.prank(nonAdmin);
        assertEq(yieldStrategyF.getPendingYield(address(token1)), 0, "no position => 0");
    }

    function test_GetPending_DisabledTokenReturnsAccrued() public {
        _deposit(user1, 1000 ether); // user1 has a position
        vm.prank(user1);
        // token2 not enabled => _pendingYield returns userAccrued (0)
        assertEq(yieldStrategyF.getPendingYield(address(token2)), 0, "disabled token pending => stored accrued (0)");
    }

    function test_GetPending_NoYieldReturnsAccrued() public {
        _deposit(user1, 1000 ether); // enabled, totalPrincipal>0, but no yield accrued
        vm.prank(user1);
        // currentBalance == lastRecordedBalance => _accrued path skipped; accYield <= entry => returns userAccrued
        assertEq(yieldStrategyF.getPendingYield(address(token1)), 0, "no yield => 0 pending");
    }

    function test_GetPending_WithYield() public {
        _deposit(user1, 5000 ether);
        uint256 simulated = 400 ether;
        mockPool.simulateYield(address(diamond), simulated);

        uint256 expectedUserShare = simulated * (10_000 - PROTOCOL_SHARE_BPS) / 10_000;
        vm.prank(user1);
        // currentBalance > lastRecordedBalance, accrued > 0, accYield > entry => delta path
        assertEq(yieldStrategyF.getPendingYield(address(token1)), expectedUserShare, "pending = user share");
    }

    function test_GetYieldPosition_NoPosition() public view {
        YieldPosition memory pos = yieldStrategyF.getYieldPosition(nonAdmin, address(token1));
        assertEq(pos.principal, 0, "zeroed principal");
        assertEq(pos.userAccrued, 0, "zeroed accrued");
        assertEq(pos.entryAccYieldPerPrincipalRay, 0, "zeroed entry");
    }

    function test_GetYieldPosition_WithPosition() public {
        _deposit(user1, 1000 ether);
        YieldPosition memory pos = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos.principal, (1000 ether * uint256(ALLOCATION_BPS)) / 10_000, "principal recorded");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // _rebalanceForWithdrawal — via withdrawCollateral (deficit / partial Aave)
    // ─────────────────────────────────────────────────────────────────────────

    // NOTE: The `_withdrawAmount == 0` branch of _rebalanceForWithdrawal (which delegates
    // to _rebalancePosition) is unreachable from the public surface: ProtocolFacet
    // withdrawCollateral reverts with AMOUNT_ZERO() before reaching the library, and the
    // only other callers (LibLiquidation) always pass a positive amount.

    function test_WithdrawPaused_NoRebalance() public {
        _deposit(user1, 1000 ether);
        uint256 principalBefore = yieldStrategyF.getYieldPosition(user1, address(token1)).principal;
        yieldStrategyF.setYieldPause(address(token1), true);

        // _rebalanceForWithdrawal with _withdrawAmount>0 but _shouldProcess false => early return
        vm.prank(user1);
        protocolF.withdrawCollateral(address(token1), 100 ether);

        uint256 principalAfter = yieldStrategyF.getYieldPosition(user1, address(token1)).principal;
        assertEq(principalAfter, principalBefore, "no rebalance while paused");
    }

    function test_WithdrawTargetReduction_NormalUnwind() public {
        _deposit(user1, 2000 ether); // principal 800, idle 1200
        // Withdraw 1000: collateral->1000, target 400, principal 800 > 400 targetWithdraw=400.
        // idle 1200 >= 1000 => no deficit. toWithdraw=400.
        vm.prank(user1);
        protocolF.withdrawCollateral(address(token1), 1000 ether);

        YieldPosition memory pos = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos.principal, 400 ether, "principal unwound to new target");
    }

    function test_WithdrawDeficit_RevertExceedsPrincipal() public {
        uint256 amount = 2000 ether;
        _deposit(user1, amount); // principal 800
        _deposit(user2, amount); // principal 800, Aave 1600, idle 2400

        // Drain diamond idle so a full withdraw needs more from Aave than user1's principal.
        vm.prank(address(diamond));
        token1.transfer(address(2), 1500 ether); // idle 900

        // user1 withdraws 2000: balance 900 < 2000 deficit 1100 > principal 800 => revert
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("YIELD_LIQUIDITY_DEFICIT(address,uint256)", address(token1), uint256(1100 ether)));
        protocolF.withdrawCollateral(address(token1), amount);
    }

    function test_WithdrawDeficit_DeficitDominatesTarget() public {
        uint256 amount = 2000 ether;
        _deposit(user1, amount); // principal 800, idle 1200
        _deposit(user2, amount); // principal 800, Aave 1600, idle 2400

        // Drain idle to 200 so the deficit (300) exceeds the target reduction (200).
        vm.prank(address(diamond));
        token1.transfer(address(2), 2200 ether); // idle 200

        // user1 withdraws 500: collateral->1500 target 600, principal 800 targetWithdraw=200.
        // balance 200 < 500 deficit=300. toWithdraw=max(200,300)=300. principal 800-300=500.
        vm.prank(user1);
        protocolF.withdrawCollateral(address(token1), 500 ether);

        YieldPosition memory pos = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos.principal, 500 ether, "principal reduced by deficit-driven withdrawal");
    }

    function test_WithdrawDeficit_DropsBelowTargetThenResupplyCapped() public {
        uint256 amount = 2000 ether;
        _deposit(user1, amount); // principal 800, idle 1200

        // Drain idle to 100 so deficit drives principal below target, exercising the
        // re-supply branch where availableToSupply == 0 (toAllocate capped to 0).
        vm.prank(address(diamond));
        token1.transfer(address(2), 1100 ether); // idle 100

        // user1 withdraws 200: collateral->1800 target 720, principal 800 targetWithdraw=80.
        // balance 100 < 200 deficit=100. toWithdraw=max(80,100)=100. principal 800-100=700 < target 720.
        // re-supply: newBalance=200, availableToSupply=200-200=0 => toAllocate capped to 0 (no supply).
        vm.prank(user1);
        protocolF.withdrawCollateral(address(token1), 200 ether);

        YieldPosition memory pos = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos.principal, 700 ether, "principal at 700 after deficit pull, no re-supply (capped)");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // _accrueYield — credit path across two distinct yield events (settle credit)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Accrual_CreditAcrossTwoYieldEvents() public {
        _deposit(user1, 4000 ether);
        mockPool.simulateYield(address(diamond), 200 ether); // first accrual
        // Rebalance triggers _accrueYield (credit) + _settlePositionYield (credit)
        vm.prank(user1);
        yieldStrategyF.rebalanceMyPosition(address(token1));

        mockPool.simulateYield(address(diamond), 100 ether); // second accrual

        uint256 totalYield = 300 ether;
        uint256 expectedUserShare = totalYield * (10_000 - PROTOCOL_SHARE_BPS) / 10_000;
        vm.prank(user1);
        uint256 claimed = yieldStrategyF.claimYield(address(token1), 0, user1);
        assertEq(claimed, expectedUserShare, "credited yield across both accrual events");
    }
}
