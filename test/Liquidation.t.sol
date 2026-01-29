// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base, MockV3Aggregator} from "./Base.t.sol";
import {PositionLiquidated, Repay, LoanLiquidated, LoanRepayment} from "../contracts/models/Event.sol";

contract LiquidationTest is Base {
    address liquidator = mkaddr("liquidator");

    function setUp() public override {
        super.setUp();
    }

    function testIsLiquidatable() public {
        createVaultAndFund(100e6); // $250/token = $25,000
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether); // $1,500/token = $6,000

        uint256 _borrowAmount = 10e6; // 5 token = $2,500

        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        bool _isLiquidatable = liquidationF.isLiquidatable(_positionId);
        assertFalse(_isLiquidatable, "user should not be liquidatable");

        MockV3Aggregator _pricefeed4 = MockV3Aggregator(pricefeed4);
        _pricefeed4.updateAnswer(1000e8); // $1.5/token

        _isLiquidatable = liquidationF.isLiquidatable(_positionId);
        uint256 _healthFactor = gettersF.getHealthFactor(_positionId, 0);
        assertTrue(_isLiquidatable, "user should be liquidatable");
        assertLt(_healthFactor, 1e18, "health factor should be less than 1");
    }

    function testLiquidatePosition_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        // Make position liquidatable
        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        vm.expectEmit(true, true, true, false);
        emit PositionLiquidated(_positionId, liquidator, address(token1), 0);
        vm.expectEmit(true, true, false, false);
        emit Repay(_positionId, address(token4), 0);
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(token1));
        vm.stopPrank();

        vm.assertGt(_borrowAmount, token4.balanceOf(liquidator));
        vm.assertLt(_t1BalanceBefore, token1.balanceOf(liquidator));
        vm.assertGt(_userCollateralBefore, gettersF.getPositionCollateral(_positionId, address(token1)));
    }

    function testLiquidatePositionWithNativeTokenCollateral_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        // Make position liquidatable
        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(1));
        uint256 _t1BalanceBefore = liquidator.balance;

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        vm.expectEmit(true, true, true, false);
        emit PositionLiquidated(_positionId, liquidator, address(1), 0);
        vm.expectEmit(true, true, false, false);
        emit Repay(_positionId, address(token4), 0);
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(1));
        vm.stopPrank();

        vm.assertGt(_borrowAmount, token4.balanceOf(liquidator));
        vm.assertLt(_t1BalanceBefore, liquidator.balance);
        vm.assertGt(_userCollateralBefore, gettersF.getPositionCollateral(_positionId, address(1)));
    }

    function testLiquidatePosition_RevertNotLiquidatable() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        // Not liquidatable yet
        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        vm.startPrank(liquidator);
        vm.expectRevert("NOT_LIQUIDATABLE()");
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(token1));
        vm.stopPrank();
    }

    function testLiquidatePosition_RevertInsufficientAllowance() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        token4.mint(liquidator, _borrowAmount);
        // No approval

        vm.startPrank(liquidator);
        vm.expectRevert("INSUFFICIENT_ALLOWANCE()");
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(token1));
        vm.stopPrank();
    }

    function testLiquidatePosition_RevertInsufficientBalance() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        vm.startPrank(liquidator);
        // No mint, but approve
        token4.approve(address(liquidationF), _borrowAmount);
        vm.expectRevert("INSUFFICIENT_BALANCE()");
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(token1));
        vm.stopPrank();
    }

    function testLiquidatePosition_RevertNoActiveBorrow() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        token4.mint(liquidator, 10e6);
        token4.approve(address(liquidationF), 10e6);

        vm.startPrank(liquidator);
        vm.expectRevert();
        liquidationF.liquidatePosition(_positionId, 10e6, address(token4), address(token1));
        vm.stopPrank();
    }

    function testLiquidatePosition_RevertNoCollateral() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        // Use a token with no collateral
        vm.startPrank(liquidator);
        vm.expectRevert();
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(token2));
        vm.stopPrank();
    }

    //===========================================================================//
    //                            Loans liquidation tests                        //
    //===========================================================================//
    function testLoanIsLiquidatable() public {
        positionManagerF.whitelistAddress(user1);
        createVaultAndFund(100e6); // $250/token = $25,000
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether); // $1,500/token = $6,000

        uint256 _borrowAmount = 10e6; // 5 token = $2,500

        vm.startPrank(user1);
        protocolF.takeLoan(address(token4), _borrowAmount, 365 days);
        vm.stopPrank();

        bool _isLiquidatable = liquidationF.isLiquidatable(_positionId);
        assertFalse(_isLiquidatable, "user should not be liquidatable");

        MockV3Aggregator _pricefeed4 = MockV3Aggregator(pricefeed4);
        _pricefeed4.updateAnswer(1000e8); // $1.5/token

        _isLiquidatable = liquidationF.isLiquidatable(_positionId);
        uint256 _healthFactor = gettersF.getHealthFactor(_positionId, 0);
        assertTrue(_isLiquidatable, "user should be liquidatable");
        assertLt(_healthFactor, 1e18, "health factor should be less than 1");
    }

    function testLiquidateLoan_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 90 days);
        vm.stopPrank();

        // Make position liquidatable
        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        vm.expectEmit(true, true, true, false);
        emit LoanLiquidated(_positionId, _loanId, address(token1), liquidator, 0);
        vm.expectEmit(true, true, false, false);
        emit LoanRepayment(_positionId, _loanId, address(token4), 0);
        liquidationF.liquidateLoan(_loanId, _borrowAmount, address(token1));
        vm.stopPrank();

        vm.assertGt(_borrowAmount, token4.balanceOf(liquidator));
        vm.assertLt(_t1BalanceBefore, token1.balanceOf(liquidator));
        vm.assertGt(_userCollateralBefore, gettersF.getPositionCollateral(_positionId, address(token1)));
    }

    function testLiquidateLoanWithNativeTokenCollateral_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 90 days);
        vm.stopPrank();

        // Make position liquidatable
        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(1));
        uint256 _t1BalanceBefore = liquidator.balance;

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        vm.expectEmit(true, true, true, false);
        emit LoanLiquidated(_positionId, _loanId, address(1), liquidator, 0);
        vm.expectEmit(true, true, false, false);
        emit LoanRepayment(_positionId, _loanId, address(token4), 0);
        liquidationF.liquidateLoan(_loanId, _borrowAmount, address(1));
        vm.stopPrank();

        vm.assertGt(_borrowAmount, token4.balanceOf(liquidator));
        vm.assertLt(_t1BalanceBefore, liquidator.balance);
        vm.assertGt(_userCollateralBefore, gettersF.getPositionCollateral(_positionId, address(1)));
    }

    function testLiquidateLoan_RevertNotLiquidatable() public {
        createVaultAndFund(100e6);
        depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 90 days);
        vm.stopPrank();

        // Not liquidatable yet
        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        vm.startPrank(liquidator);
        vm.expectRevert("NOT_LIQUIDATABLE()");
        liquidationF.liquidateLoan(_loanId, _borrowAmount, address(token1));
        vm.stopPrank();
    }

    function testLiquidateLoan_RevertInsufficientAllowance() public {
        createVaultAndFund(100e6);
        depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 90 days);
        vm.stopPrank();

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        token4.mint(liquidator, _borrowAmount);
        // No approval

        vm.startPrank(liquidator);
        vm.expectRevert("INSUFFICIENT_ALLOWANCE()");
        liquidationF.liquidateLoan(_loanId, _borrowAmount, address(token1));
        vm.stopPrank();
    }

    function testLiquidateLoan_RevertInsufficientBalance() public {
        createVaultAndFund(100e6);
        depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 90 days);
        vm.stopPrank();

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        vm.startPrank(liquidator);
        // No mint, but approve
        token4.approve(address(liquidationF), _borrowAmount);
        vm.expectRevert("INSUFFICIENT_BALANCE()");
        liquidationF.liquidateLoan(_loanId, _borrowAmount, address(token1));
        vm.stopPrank();
    }

    function testLiquidateLoan_RevertNoActiveBorrow() public {
        createVaultAndFund(100e6);
        depositCollateralFor(user1, address(token1), 4 ether);

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        token4.mint(liquidator, 10e6);
        token4.approve(address(liquidationF), 10e6);

        vm.startPrank(liquidator);
        vm.expectRevert("INACTIVE_LOAN()");
        liquidationF.liquidateLoan(1, 10e6, address(token1));
        vm.stopPrank();
    }

    function testLiquidateLoan_RevertNoCollateral() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether);

        uint256 _borrowAmount = 10e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        MockV3Aggregator(pricefeed4).updateAnswer(1000e8);

        token4.mint(liquidator, _borrowAmount);
        token4.approve(address(liquidationF), _borrowAmount);

        // Use a token with no collateral
        vm.startPrank(liquidator);
        vm.expectRevert();
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(token2));
        vm.stopPrank();
    }
}
