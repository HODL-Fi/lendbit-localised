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
}
