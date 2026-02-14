// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base, MockV3Aggregator} from "./Base.t.sol";
import {LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";
import {LibLiquidation} from "../contracts/libraries/LibLiquidation.sol";
import {NO_COLLATERAL_FOR_TOKEN} from "../contracts/models/Error.sol";
import {LoanStatus} from "../contracts/models/Protocol.sol";
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

        uint256 _borrowAmount = 15e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);

        uint256 _debt = gettersF.getBorrowDetails(_positionId, address(token4));

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1200e8);

        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);
        uint256 _vaultAssetBefore = vaultManagerF.getVaultTotalAssets(address(token4));

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _debt);
        token4.approve(address(liquidationF), _debt);

        vm.expectEmit(true, true, true, false);
        emit PositionLiquidated(_positionId, liquidator, address(token1), 0);
        vm.expectEmit(true, true, true, false);
        emit Repay(_positionId, address(token4), 0);
        liquidationF.liquidatePosition(_positionId, _debt, address(token4), address(token1));
        vm.stopPrank();

        uint256 _userCollateralNow = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _liquidatorBalance = token1.balanceOf(liquidator);

        assertEq(gettersF.getBorrowDetails(_positionId, address(token4)), 0); // new outstanding debt is zero
        assertEq(_userCollateralBefore, _userCollateralNow + _liquidatorBalance);
        assertEq(_vaultAssetBefore + _debt, vaultManagerF.getVaultTotalAssets(address(token4)));
        assertGt(_borrowAmount, token4.balanceOf(liquidator));
        assertLt(_t1BalanceBefore, token1.balanceOf(liquidator));
    }

    function testLiquidatePositionWithNativeTokenCollateral_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(1), 4 ether);

        uint256 _borrowAmount = 15e6;
        vm.startPrank(user1);
        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1200e8);

        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _debt = gettersF.getBorrowDetails(_positionId, address(token4));
        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(1));
        uint256 _vaultAssetBefore = vaultManagerF.getVaultTotalAssets(address(token4));
        uint256 _t1BalanceBefore = liquidator.balance;

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _debt);
        token4.approve(address(liquidationF), _debt);

        vm.expectEmit(true, true, true, false);
        emit PositionLiquidated(_positionId, liquidator, address(1), _debt);
        vm.expectEmit(true, true, true, false);
        emit Repay(_positionId, address(token4), _debt);
        liquidationF.liquidatePosition(_positionId, _debt, address(token4), address(1));
        vm.stopPrank();

        uint256 _userCollateralNow = gettersF.getPositionCollateral(_positionId, address(1));
        assertEq(gettersF.getBorrowDetails(_positionId, address(token4)), 0); // new outstanding debt is zero
        assertEq(_userCollateralBefore, _userCollateralNow + liquidator.balance);
        assertEq(_vaultAssetBefore + _debt, vaultManagerF.getVaultTotalAssets(address(token4)));
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
        uint256 _positionId = depositCollateralFor(user1, address(token1), 5 ether); // $7500

        uint256 _borrowAmount = 20e6;
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 365 days); // $5000
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId); // 24e6 token4 @ $250 -> $6000

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1350e8); // collateral now worth $6750 within liquidation range
        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);
        uint256 _vaultAssetBefore = vaultManagerF.getVaultTotalAssets(address(token4));

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _debt);
        token4.approve(address(liquidationF), _debt);

        vm.expectEmit(true, true, true, false);
        emit LoanLiquidated(_positionId, _loanId, address(token1), liquidator, _debt);
        vm.expectEmit(true, true, true, false);
        emit LoanRepayment(_positionId, _loanId, address(token4), _debt);
        liquidationF.liquidateLoan(_loanId, _debt, address(token1));
        vm.stopPrank();

        (,, uint256 principal, uint256 repaid,,, uint256 debt,,, uint8 status) = gettersF.getLoanDetails(_loanId);

        // liquidator should receive $6000 worth of token1 and 10% liquidation bonus
        // Liquidator should receive 4.88...e18 token1
        uint256 _userCollateralNow = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _liquidatorBalance = token1.balanceOf(liquidator);
        assertEq(repaid, _debt);
        assertEq(debt, 0); // new outstanding debt from loan details is zero
        assertEq(principal, _borrowAmount);
        assertEq(uint8(LoanStatus.LIQUIDATED), status);
        assertEq(_userCollateralBefore, _userCollateralNow + _liquidatorBalance);
        assertEq(_vaultAssetBefore + _debt, vaultManagerF.getVaultTotalAssets(address(token4)));
        assertGt(_borrowAmount, token4.balanceOf(liquidator));
        assertLt(_t1BalanceBefore, token1.balanceOf(liquidator));
    }

    function testLiquidateLoanPartial_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 5 ether); // $7500

        uint256 _borrowAmount = 20e6;
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 365 days); // $5000
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId); // 24e6 token4 @ $250 -> $6000

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1350e8); // collateral now worth $6750 within liquidation range
        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);
        uint256 _vaultAssetBefore = vaultManagerF.getVaultTotalAssets(address(token4));

        uint256 _payback = _debt / 2; // payback half the loan

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _payback);
        token4.approve(address(liquidationF), _payback);

        vm.expectEmit(true, true, true, false);
        emit LoanLiquidated(_positionId, _loanId, address(token1), liquidator, _payback);
        vm.expectEmit(true, true, true, false);
        emit LoanRepayment(_positionId, _loanId, address(token4), _payback);
        liquidationF.liquidateLoan(_loanId, _payback, address(token1));
        vm.stopPrank();

        (,, uint256 principal, uint256 repaid,,, uint256 debt,,, uint8 status) = gettersF.getLoanDetails(_loanId);

        // liquidator should receive $6000 worth of token1 and 10% liquidation bonus
        // Liquidator should receive 4.88...e18 token1
        uint256 _userCollateralNow = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _liquidatorBalance = token1.balanceOf(liquidator);
        assertEq(repaid, _payback);
        assertEq(debt, (_debt - _payback)); // new outstanding debt from loan details is minus the repaid
        assertEq(principal, ((_borrowAmount * 120 / 100) - _payback)); // the new principal used to calculate the outstanding debt
        assertEq(uint8(LoanStatus.FULFILLED), status); // loan is still open
        assertEq(_userCollateralBefore, _userCollateralNow + _liquidatorBalance);
        assertEq(_vaultAssetBefore + _payback, vaultManagerF.getVaultTotalAssets(address(token4)));
        assertGt(_borrowAmount, token4.balanceOf(liquidator));
        assertLt(_t1BalanceBefore, token1.balanceOf(liquidator));
    }

    function testLiquidateLoanWithNativeTokenCollateral_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(1), 4 ether); // 4 tokens @ $1500 = $6000

        uint256 _borrowAmount = 10e6; // 10 tokens @ 250 = $2500
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 365 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId); // 12 tokens = 12 * 250 = $3000

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(900e8); // collateral at $3600 (4 * 900) -> liquidation zone

        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(1));
        uint256 _t1BalanceBefore = liquidator.balance;
        uint256 _vaultAssetBefore = vaultManagerF.getVaultTotalAssets(address(token4));

        vm.startPrank(liquidator);
        // Give liquidator enough allowance and balance
        token4.mint(liquidator, _debt);
        token4.approve(address(liquidationF), _debt);

        vm.expectEmit(true, true, true, false);
        emit LoanLiquidated(_positionId, _loanId, address(1), liquidator, _debt);
        vm.expectEmit(true, true, false, false);
        emit LoanRepayment(_positionId, _loanId, address(token4), _debt);
        liquidationF.liquidateLoan(_loanId, _debt, address(1));
        vm.stopPrank();

        (,, uint256 principal, uint256 repaid,,, uint256 debt,,, uint8 status) = gettersF.getLoanDetails(_loanId);

        uint256 _userCollateralNow = gettersF.getPositionCollateral(_positionId, address(1));
        uint256 _liquidatorBalance = liquidator.balance;

        // test checks
        assertEq(repaid, _debt);
        assertEq(debt, 0); // new outstanding debt from loan details is zero
        assertEq(principal, _borrowAmount);
        assertEq(uint8(LoanStatus.LIQUIDATED), status);
        assertEq(_userCollateralBefore, _userCollateralNow + _liquidatorBalance);
        assertEq(_vaultAssetBefore + _debt, vaultManagerF.getVaultTotalAssets(address(token4)));
        assertGt(_borrowAmount, token4.balanceOf(liquidator));
        assertLt(_t1BalanceBefore, _liquidatorBalance);
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
        vm.expectRevert(abi.encodeWithSelector(NO_COLLATERAL_FOR_TOKEN.selector, _positionId, address(token2)));
        liquidationF.liquidatePosition(_positionId, _borrowAmount, address(token4), address(token2));
        vm.stopPrank();
    }

    function testGetAmountToLiquidate() public {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        uint256 _positionId = 1;
        address _collateralToken = address(token1);
        address _debtToken = address(token3);
        uint256 _amount = 1000e6;

        s.s_supportedCollateralTokens[_collateralToken] = true;
        s.s_supportedToken[_debtToken] = true;
        s.s_tokenPriceFeed[_collateralToken] = pricefeed1;
        s.s_tokenPriceFeed[_debtToken] = pricefeed3;
        s.s_positionCollateral[_positionId][_collateralToken] = 4 ether;
        s.s_supportedCollateralTokens[_debtToken] = true;
        s.s_positionCollateral[_positionId][_debtToken] = 4 ether;
        s.s_tokenVaultConfig[address(_debtToken)] = defaultConfig;
        s.s_tokenVaultConfig[address(_collateralToken)] = defaultConfig;

        uint256 _amountToLiquidate = LibLiquidation._getAmountToLiquidate(s, _debtToken, _debtToken, _amount);
        uint256 _amountToLiquidate2 = LibLiquidation._getAmountToLiquidate(s, _collateralToken, _debtToken, _amount);

        assertEq(_amountToLiquidate, (_amount * 110 / 100));
        assertEq(_amountToLiquidate2, 733333333333333332); // 0.6666... token 1 == $1000 + 10% (0.0666...) -> 0.7333...
    }
}
