// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

import {MockAavePool} from "../contracts/mocks/MockAavePool.sol";
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
}
