// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

import {Vm} from "forge-std/Vm.sol";
import {MockAavePool} from "../contracts/mocks/MockAavePool.sol";
import {MockMismatchPool, MockRevertingPool} from "../contracts/mocks/MockMismatchPool.sol";
import {YieldPosition} from "../contracts/models/Yield.sol";
import {Base} from "./Base.t.sol";

contract YieldStrategyTest is Base {
    MockAavePool internal mockPool;

    uint16 internal constant ALLOCATION_BPS = 4000; // 40%
    uint16 internal constant PROTOCOL_SHARE_BPS = 1500; // 15%

    function setUp() public override {
        super.setUp();
        mockPool = new MockAavePool(address(token1), token1.decimals());
        vm.label(address(mockPool), "MockAavePool");

        yieldStrategyF.configureYieldToken(
            address(token1), address(mockPool), address(mockPool.aToken()), ALLOCATION_BPS, PROTOCOL_SHARE_BPS
        );
    }

    function testDepositAllocatesCollateralToAave() public {
        uint256 depositAmount = 1_000 ether;
        mintTokenTo(address(token1), user1, depositAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        YieldPosition memory position = yieldStrategyF.getYieldPosition(user1, address(token1));
        uint256 expectedPrincipal = (depositAmount * ALLOCATION_BPS) / 10_000;
        assertEq(position.principal, expectedPrincipal, "principal stored");

        ERC20Mock aToken = mockPool.aToken();
        assertEq(aToken.balanceOf(address(diamond)), expectedPrincipal, "aToken balance updated");
        assertEq(token1.balanceOf(address(mockPool)), expectedPrincipal, "underlying moved to pool");
    }

    function testWithdrawUnwindsYieldAllocation() public {
        uint256 depositAmount = 2_000 ether;
        mintTokenTo(address(token1), user1, depositAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        protocolF.withdrawCollateral(address(token1), depositAmount / 2);
        vm.stopPrank();

        YieldPosition memory position = yieldStrategyF.getYieldPosition(user1, address(token1));
        uint256 remainingCollateral = depositAmount / 2;
        uint256 expectedPrincipal = (remainingCollateral * ALLOCATION_BPS) / 10_000;
        assertEq(position.principal, expectedPrincipal, "principal rebalanced after withdraw");
    }

    function testUsersCanClaimYieldShare() public {
        uint256 depositAmount = 5_000 ether;
        mintTokenTo(address(token1), user1, depositAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 simulatedYield = 500 ether;
        mockPool.simulateYield(address(diamond), simulatedYield);

        vm.startPrank(user1);
        uint256 pending = yieldStrategyF.getPendingYield(address(token1));
        uint256 expectedUserShare = simulatedYield * (10_000 - PROTOCOL_SHARE_BPS) / 10_000;
        assertEq(pending, expectedUserShare, "pending matches user share");

        uint256 balanceBefore = token1.balanceOf(user1);
        yieldStrategyF.claimYield(address(token1), 0, address(0));
        uint256 balanceAfter = token1.balanceOf(user1);
        uint256 pendingAfter = yieldStrategyF.getPendingYield(address(token1));
        vm.stopPrank();

        assertEq(balanceAfter - balanceBefore, expectedUserShare, "user received yield");
        assertEq(pendingAfter, 0, "pending cleared");
    }

    function testProtocolCanHarvestShare() public {
        uint256 depositAmount = 3_000 ether;
        mintTokenTo(address(token1), user1, depositAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 simulatedYield = 300 ether;
        mockPool.simulateYield(address(diamond), simulatedYield);

        uint256 expectedProtocolShare = simulatedYield * PROTOCOL_SHARE_BPS / 10_000;
        uint256 balanceBefore = token1.balanceOf(address(this));
        yieldStrategyF.harvestProtocolYield(address(token1), address(this), 0);
        uint256 balanceAfter = token1.balanceOf(address(this));

        assertEq(balanceAfter - balanceBefore, expectedProtocolShare, "protocol harvested share");
    }

    function testDeficitRevertsWhenExceedingPrincipal() public {
        uint256 amount = 2000 ether;

        // Two users deposit equal collateral
        mintTokenTo(address(token1), user1, amount);
        vm.startPrank(user1);
        token1.approve(address(diamond), amount);
        protocolF.depositCollateral(address(token1), amount);
        vm.stopPrank();

        mintTokenTo(address(token1), user2, amount);
        vm.startPrank(user2);
        token1.approve(address(diamond), amount);
        protocolF.depositCollateral(address(token1), amount);
        vm.stopPrank();

        // Both positions: principal = 800 each, Aave holds 1600, Diamond holds 2400 idle

        // Simulate someone taking a loan or transferring out of Diamond, making idle balance low
        // For testing, we just burn/transfer out from the diamond directly
        vm.prank(address(diamond));
        token1.transfer(address(1), 1500 ether); // Diamond now has 900 idle

        // User1 tries to withdraw all their collateral (2000)
        // Diamond has 900. Deficit = 1100.
        // User1 principal = 800. Deficit > principal. It will revert!
        vm.prank(user1);
        vm.expectRevert();
        protocolF.withdrawCollateral(address(token1), amount);
    }

    function testPartialWithdrawalReverts() public {
        uint256 amount = 2000 ether;

        mintTokenTo(address(token1), user1, amount);
        vm.startPrank(user1);
        token1.approve(address(diamond), amount);
        protocolF.depositCollateral(address(token1), amount);
        vm.stopPrank();

        mintTokenTo(address(token1), user2, amount);
        vm.startPrank(user2);
        token1.approve(address(diamond), amount);
        protocolF.depositCollateral(address(token1), amount);
        vm.stopPrank();

        // Simulate Diamond losing idle tokens (e.g. lent out)
        vm.prank(address(diamond));
        token1.transfer(address(1), 2200 ether); // Diamond now has 200 idle

        // User1 tries to withdraw 500
        // amount = 500. balance = 200. deficit = 300.
        // _rebalanceForWithdrawal calculates targetWithdraw = 800 - 600 = 200.
        // toWithdraw = max(200, 300) = 300.
        // withdraws 300 from Aave. position1.principal = 800 - 300 = 500.
        // It successfully covers the withdrawal without reverting.
        vm.prank(user1);
        protocolF.withdrawCollateral(address(token1), 500 ether);

        YieldPosition memory pos1 = yieldStrategyF.getYieldPosition(user1, address(token1));
        assertEq(pos1.principal, 500 ether, "principal should be reduced by deficit");
    }

    function testDeficitChargedToWithdrawer() public {
        uint256 amount = 2000 ether;

        // Two users deposit equal collateral
        mintTokenTo(address(token1), user1, amount);
        vm.startPrank(user1);
        token1.approve(address(diamond), amount);
        protocolF.depositCollateral(address(token1), amount);
        vm.stopPrank();

        mintTokenTo(address(token1), user2, amount);
        vm.startPrank(user2);
        token1.approve(address(diamond), amount);
        protocolF.depositCollateral(address(token1), amount);
        vm.stopPrank();

        // Both positions: principal = 800 each, Aave holds 1600, Diamond holds 2400 idle

        // User1 withdraws all their collateral
        vm.prank(user1);
        protocolF.withdrawCollateral(address(token1), amount);

        // Check: user1's position took the full Aave withdrawal hit
        YieldPosition memory pos1 = yieldStrategyF.getYieldPosition(user1, address(token1));
        YieldPosition memory pos2 = yieldStrategyF.getYieldPosition(user2, address(token1));

        // User1's principal went to 0, user2's stays at initial principal
        assertEq(pos1.principal, 0);
        assertEq(pos2.principal, (amount * ALLOCATION_BPS) / 10000);
        // User1 had to redeem from Aave, user2 was unaffected
    }

    function testDoubleWithdrawalOnCollateralWithdraw() public {
        uint256 deposit = 2000 ether;
        mintTokenTo(address(token1), user1, deposit);
        vm.startPrank(user1);
        token1.approve(address(diamond), deposit);
        protocolF.depositCollateral(address(token1), deposit);
        // Diamond holds 1200 idle, Aave holds 800 (40%)

        // Reduce Diamond's idle balance by sending 600 ether to another address
        // so that the idle balance becomes 600 ether (instead of 1200)
        vm.stopPrank();
        vm.prank(address(diamond));
        token1.transfer(address(1), 600 ether);

        // Withdraw 1200 tokens:
        // 1. New collateral = 2000 - 1200 = 800, target principal = 800 * 40% = 320.
        //    Current principal = 800. Target withdrawal = 800 - 320 = 480.
        // 2. Idle balance is 600. Withdraw amount is 1200. Deficit withdrawal = 1200 - 600 = 600.
        // Under the old code, both _rebalancePosition (withdrawing 480) and _ensureSufficientIdle (withdrawing 120) would trigger Aave withdrawals.
        // In the fixed code, a single withdrawal of max(480, 600) = 600 is triggered.
        vm.startPrank(user1);
        vm.recordLogs();
        protocolF.withdrawCollateral(address(token1), 1200 ether);
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint256 yieldReleasedCount = 0;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("YieldReleased(uint256,address,uint256)")) {
                yieldReleasedCount++;
            }
        }

        // Assert that only a single Aave withdrawal (YieldReleased event) is triggered.
        assertEq(yieldReleasedCount, 1, "Should only perform a single Aave withdrawal");
    }

    /// @notice Tests the math invariants around yield accrual and claiming.
    /// Invariant 1: Claiming yield does not reduce the Aave balance below totalPrincipal.
    /// Invariant 2: Yield continues to accrue correctly on the remaining Aave balance, 
    /// dividing by totalPrincipal safely without creating insolvency.
    /// Invariant 3: The protocol remains fully solvent (users can withdraw all collateral 
    /// and the protocol can harvest its yield) even after asynchronous yield claims.
    function testYieldClaimMaintainsInvariants() public {
        uint256 depositAmount = 10_000 ether;
        
        // 1. Two users deposit equal amounts
        mintTokenTo(address(token1), user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        mintTokenTo(address(token1), user2, depositAmount);
        vm.startPrank(user2);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        // Total principal in Aave is 40% of 20_000 = 8_000 ether.
        uint256 expectedTotalPrincipal = (20_000 ether * uint256(ALLOCATION_BPS)) / 10_000;
        
        // 2. Simulate yield generation
        uint256 simulatedYield = 1_000 ether;
        mockPool.simulateYield(address(diamond), simulatedYield);

        // 3. User1 claims their yield
        vm.startPrank(user1);
        yieldStrategyF.claimYield(address(token1), 0, user1);
        vm.stopPrank();

        // 4. Invariant 1: Aave balance >= totalPrincipal
        ERC20Mock aToken = mockPool.aToken();
        uint256 aTokenBalance = aToken.balanceOf(address(diamond));
        assertGe(aTokenBalance, expectedTotalPrincipal, "Invariant 1: Aave balance >= totalPrincipal");

        // 5. Simulate more yield generation on the smaller base
        uint256 simulatedYield2 = 500 ether;
        mockPool.simulateYield(address(diamond), simulatedYield2);

        // 6. User2 claims their yield (includes their share of first and second yield)
        vm.startPrank(user2);
        yieldStrategyF.claimYield(address(token1), 0, user2);
        vm.stopPrank();

        // 7. Verify Invariant 2 & 3: Protocol is solvent
        // Both users withdraw all their collateral
        vm.startPrank(user1);
        protocolF.withdrawCollateral(address(token1), depositAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        protocolF.withdrawCollateral(address(token1), depositAmount);
        vm.stopPrank();

        // User1 claims remaining yield that accrued before their withdrawal
        vm.startPrank(user1);
        yieldStrategyF.claimYield(address(token1), 0, user1);
        vm.stopPrank();

        // 8. Protocol harvests its yield
        uint256 balanceBefore = token1.balanceOf(address(this));
        yieldStrategyF.harvestProtocolYield(address(token1), address(this), 0);
        uint256 balanceAfter = token1.balanceOf(address(this));

        // The protocol's share should be exactly PROTOCOL_SHARE_BPS of total simulated yield
        uint256 expectedProtocolShare = ((simulatedYield + simulatedYield2) * PROTOCOL_SHARE_BPS) / 10_000;
        assertEq(balanceAfter - balanceBefore, expectedProtocolShare, "Invariant 3: Protocol harvested correct share");

        // After everything is withdrawn and harvested, the aToken balance should be 0 
        uint256 finalATokenBalance = aToken.balanceOf(address(diamond));
        assertEq(finalATokenBalance, 0, "Invariant 3: Fully solvent, Aave pool drained cleanly");
    }

    // ─── Failure-path tests for _configureYieldToken (L36-L40) ───────────────

    /// @notice Pool is a valid contract but getReserveAToken returns a different
    ///         address from the one supplied → POOL_TOKEN_MISMATCH must revert.
    function testConfigureRevertsOnPoolTokenMismatch() public {
        // Deploy a fresh token so there's no existing config to interfere with.
        ERC20Mock freshToken = new ERC20Mock(18);

        // The caller claims the aToken is `address(mockPool.aToken())`,
        // but MockMismatchPool always returns `address(1)` instead.
        MockMismatchPool mismatchPool = new MockMismatchPool(address(1));

        // The address we tell the library is the correct aToken (anything ≠ what the pool returns).
        address claimedAToken = address(mockPool.aToken());

        vm.expectRevert(
            abi.encodeWithSignature("POOL_TOKEN_MISMATCH(address,address)", address(mismatchPool), claimedAToken)
        );
        yieldStrategyF.configureYieldToken(
            address(freshToken),
            address(mismatchPool), // pool returns address(1), not claimedAToken
            claimedAToken,
            ALLOCATION_BPS,
            PROTOCOL_SHARE_BPS
        );
    }

    /// @notice Pool is a contract but getReserveAToken reverts internally, so the
    ///         `catch` block in _configureYieldToken fires and throws BAD_POOL_ADDRESS.
    ///
    ///         NOTE: An EOA cannot be used here. Calling an EOA returns 0 bytes,
    ///         which causes an ABI-decoding panic (0 bytes → can't decode `address`)
    ///         that Solidity's try/catch does NOT intercept, leaking the raw panic
    ///         instead of the custom BAD_POOL_ADDRESS error.
    function testConfigureRevertsOnBadPoolAddress() public {
        ERC20Mock freshToken = new ERC20Mock(18);

        // Deploy a contract that always reverts in getReserveAToken.
        // The try/catch in LibYieldStrategy will catch the revert and
        // re-throw it as BAD_POOL_ADDRESS.
        MockRevertingPool revertingPool = new MockRevertingPool();
        address anyAToken = address(mockPool.aToken());

        vm.expectRevert(
            abi.encodeWithSignature("BAD_POOL_ADDRESS(address)", address(revertingPool))
        );
        yieldStrategyF.configureYieldToken(
            address(freshToken),
            address(revertingPool),
            anyAToken,
            ALLOCATION_BPS,
            PROTOCOL_SHARE_BPS
        );
    }
}

