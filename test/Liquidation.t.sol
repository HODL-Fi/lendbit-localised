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
        protocolF.takeLoan(address(token4), _borrowAmount / 2, 30 days);
        vm.stopPrank();

        bool _isLiquidatable = liquidationF.isLiquidatable(_positionId);
        assertFalse(_isLiquidatable, "user should not be liquidatable");

        MockV3Aggregator _pricefeed1 = MockV3Aggregator(pricefeed1);
        _pricefeed1.updateAnswer(1000e8); // collateral price drop @ $4000

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
        updatePricefeedsData(); // to update lastupdated timestamp

        uint256 _debt = gettersF.getBorrowDetails(_positionId, address(token4));

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1200e8);

        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);
        uint256 _vaultBalanceBefore = token4.balanceOf(gettersF.getTokenVault(address(token4)));
        uint256 _vaultTotalAssetBefore = gettersF.getVaultTotalAssets(address(token4));

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
        assertEq(_vaultBalanceBefore + _debt, token4.balanceOf(gettersF.getTokenVault(address(token4))));
        assertLe(_vaultTotalAssetBefore, gettersF.getVaultTotalAssets(address(token4))); // vault accrual and pooled positions now share the fixed rate, so assets only grow on repayment
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
        updatePricefeedsData();

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1200e8);

        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _debt = gettersF.getBorrowDetails(_positionId, address(token4));
        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(1));
        uint256 _vaultBalanceBefore = token4.balanceOf(gettersF.getTokenVault(address(token4)));
        uint256 _vaultTotalAssetBefore = gettersF.getVaultTotalAssets(address(token4));
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
        assertEq(_vaultBalanceBefore + _debt, token4.balanceOf(gettersF.getTokenVault(address(token4))));
        assertLe(_vaultTotalAssetBefore, gettersF.getVaultTotalAssets(address(token4))); // vault accrual and pooled positions now share the fixed rate, so assets only grow on repayment
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
        updatePricefeedsData();

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId); // 24e6 token4 @ $250 -> $6000

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1320e8); // collateral now worth $6750 within liquidation range
        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);
        uint256 _vaultBalanceBefore = token4.balanceOf(gettersF.getTokenVault(address(token4)));
        uint256 _vaultTotalAssetBefore = gettersF.getVaultTotalAssets(address(token4));

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
        assertEq(_vaultBalanceBefore + _debt, token4.balanceOf(gettersF.getTokenVault(address(token4))));
        assertEq(_vaultTotalAssetBefore, gettersF.getVaultTotalAssets(address(token4))); // should be equal because total assets adds debt loans
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
        updatePricefeedsData();

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId); // 24e6 token4 @ $250 -> $6000

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1320e8); // collateral now worth $6750 within liquidation range
        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _t1BalanceBefore = token1.balanceOf(liquidator);
        uint256 _vaultBalanceBefore = token4.balanceOf(gettersF.getTokenVault(address(token4)));
        uint256 _vaultTotalAssetBefore = gettersF.getVaultTotalAssets(address(token4));

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

        // Allocation is pro-rata across principal and interest (#4): a `_payback`
        // of `_debt/2` retires half of the principal, not "interest-first".
        uint256 _principalRepaid = (_payback * _borrowAmount) / _debt;
        uint256 _expectedPrincipal = _borrowAmount - _principalRepaid;
        // The interest anchor is NOT reset on a partial liquidation (#2), so the
        // accrued interest on the surviving principal is retained rather than
        // forgiven. At maturity the remaining principal has accrued the same rate
        // fraction as the original loan, so outstanding debt is that principal
        // grossed up by the loan's rate: `principal * originalDebt / originalPrincipal`.
        uint256 _expectedDebt = (_expectedPrincipal * _debt) / _borrowAmount;
        uint256 _userCollateralNow = gettersF.getPositionCollateral(_positionId, address(token1));
        uint256 _liquidatorBalance = token1.balanceOf(liquidator);
        assertEq(repaid, _payback);
        assertEq(principal, _expectedPrincipal); // remaining principal after pro-rata reduction
        assertEq(debt, _expectedDebt); // remaining principal + retained accrued interest (#2)
        assertEq(uint8(LoanStatus.FULFILLED), status); // loan is still open
        assertEq(_userCollateralBefore, _userCollateralNow + _liquidatorBalance);
        assertEq(_vaultBalanceBefore + _payback, token4.balanceOf(gettersF.getTokenVault(address(token4))));
        assertEq(_vaultTotalAssetBefore, gettersF.getVaultTotalAssets(address(token4))); // should be equal because total assets adds debt loans
        assertGt(_borrowAmount, token4.balanceOf(liquidator));
        assertLt(_t1BalanceBefore, token1.balanceOf(liquidator));
    }

    /// @notice Finding #4a — a deeply-overdue loan whose bonus-adjusted
    ///         interest+penalty exceeds the remaining collateral used to be
    ///         permanently un-liquidatable (seizure-revert deadlocked against the
    ///         interest floor) → its principal became bad debt. The fix caps the
    ///         seizure to available collateral and retires principal pro-rata, so
    ///         the loan can still be liquidated.
    function testLiquidateLoan_overduePenaltyExceedsCollateral_stillLiquidatable() public {
        createVaultAndFund(1_000e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 5 ether); // $7,500

        uint256 _borrowAmount = 20e6; // $5,000
        vm.prank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 1 days);

        // Go far past maturity so the penalty (unbounded in time-overdue) makes
        // the bonus-adjusted seizure for even the interest exceed the collateral.
        vm.warp(block.timestamp + 3650 days);
        updatePricefeedsData();

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId);
        (,, uint256 _principalBefore,,,,,,,) = gettersF.getLoanDetails(_loanId);
        assertTrue(liquidationF.isLiquidatable(_positionId), "position is underwater");

        // Liquidator offers to repay the whole debt; only the scaled-down amount
        // that the collateral can back is actually pulled.
        token4.mint(liquidator, _debt);
        vm.startPrank(liquidator);
        token4.approve(address(liquidationF), _debt);
        // Pre-fix this reverted INSUFFICIENT_COLLATERAL / REPAYMENT_BELOW_INTEREST.
        liquidationF.liquidateLoan(_loanId, _debt, address(token1));
        vm.stopPrank();

        uint256 _collAfter = gettersF.getPositionCollateral(_positionId, address(token1));
        (,, uint256 _principalAfter,,,,,,,) = gettersF.getLoanDetails(_loanId);
        assertEq(_collAfter, 0, "seizure capped at and consumed all collateral");
        assertLt(_principalAfter, _principalBefore, "principal retired despite deep insolvency");
        assertGt(token1.balanceOf(liquidator), 0, "liquidator seized the collateral");
    }

    /// @notice Finding #4b — paying exactly the accrued interest used to retire
    ///         ZERO principal (interest-first) while still seizing bonus
    ///         collateral, and was repeatable in a loop because
    ///         `_outstandingBalance` ignores `repaid`. Pro-rata allocation forces
    ///         every liquidation to retire principal, so the skim is impossible.
    function testLiquidateLoan_cannotSkimInterestOnly() public {
        createVaultAndFund(1_000e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 20 ether); // ample collateral

        uint256 _borrowAmount = 20e6; // $5,000
        vm.prank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 1 days);

        vm.warp(block.timestamp + 30 days); // overdue → real interest + penalty
        updatePricefeedsData();

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId);
        (,, uint256 _principalBefore,,,,,,,) = gettersF.getLoanDetails(_loanId);
        uint256 _interestDue = _debt - _principalBefore;
        assertGt(_interestDue, 0, "loan accrued interest + penalty");

        MockV3Aggregator(pricefeed1).updateAnswer(250e8); // underwater, collateral remains
        assertTrue(liquidationF.isLiquidatable(_positionId));

        // Pay EXACTLY the accrued interest — the old skim input.
        token4.mint(liquidator, _interestDue);
        vm.startPrank(liquidator);
        token4.approve(address(liquidationF), _interestDue);
        liquidationF.liquidateLoan(_loanId, _interestDue, address(token1));
        vm.stopPrank();

        (,, uint256 _principalAfter,,,,,,,) = gettersF.getLoanDetails(_loanId);
        // Old interest-first code: _principalAfter == _principalBefore (pure skim).
        // Pro-rata: principal strictly decreased.
        assertLt(_principalAfter, _principalBefore, "interest-only payment still retires principal");
    }

    /// @notice Finding #1 (report 2026-07-01-233007) — the OPEN-ENDED liquidation
    ///         path (`_liquidatePosition`) previously used interest-first
    ///         accounting, so an interest-only payment seized bonus collateral
    ///         while the pooled principal tally stayed put — repeatable per block.
    ///         It now allocates pro-rata, so every liquidation retires principal.
    function testLiquidatePosition_cannotSkimInterestOnly() public {
        createVaultAndFund(1_000e6);
        uint256 _pid = depositCollateralFor(user1, address(token1), 10 ether);

        uint256 _borrowAmount = 20e6;
        vm.prank(user1);
        protocolF.borrow(address(token4), _borrowAmount); // open-ended (pooled) borrow

        vm.warp(block.timestamp + 180 days); // accrue interest
        updatePricefeedsData();

        uint256 _principalTallyBefore = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        assertEq(_principalTallyBefore, _borrowAmount, "tally == borrowed principal");

        uint256 _debt = gettersF.getBorrowDetails(_pid, address(token4));
        uint256 _interestOnly = _debt - _borrowAmount;
        assertGt(_interestOnly, 0, "interest accrued");

        MockV3Aggregator(pricefeed1).updateAnswer(250e8); // underwater, collateral remains
        assertTrue(liquidationF.isLiquidatable(_pid));

        // Liquidator pays ONLY the accrued interest.
        token4.mint(liquidator, _interestOnly);
        vm.startPrank(liquidator);
        token4.approve(address(liquidationF), _interestOnly);
        liquidationF.liquidatePosition(_pid, _interestOnly, address(token4), address(token1));
        vm.stopPrank();

        // Pooled principal tally strictly decreased — no interest-only skim.
        uint256 _principalTallyAfter = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        assertLt(_principalTallyAfter, _principalTallyBefore, "liquidation retired pooled principal");
    }

    /// @notice Finding #2 (report 2026-07-01-233007) — a partial fixed-loan
    ///         liquidation used to reset `startTimestamp`, forgiving accrued
    ///         interest on the surviving principal (and stranding the vault
    ///         receivable). The anchor is no longer reset, so the remaining
    ///         principal keeps carrying its accrued interest.
    function testLiquidateLoan_partial_retains_accrued_interest() public {
        createVaultAndFund(1_000e6);
        uint256 _pid = depositCollateralFor(user1, address(token1), 10 ether);

        vm.prank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), 20e6, 365 days);

        vm.warp(block.timestamp + 180 days); // mid-accrual (not yet matured)
        updatePricefeedsData();

        MockV3Aggregator(pricefeed1).updateAnswer(250e8);
        assertTrue(liquidationF.isLiquidatable(_pid));

        uint256 _pay = gettersF.getOutstandingDebtForLoan(_loanId) / 2;
        token4.mint(liquidator, _pay);
        vm.startPrank(liquidator);
        token4.approve(address(liquidationF), _pay);
        liquidationF.liquidateLoan(_loanId, _pay, address(token1));
        vm.stopPrank();

        // Outstanding debt strictly exceeds remaining principal: the accrued
        // interest on the survivor is retained, not forgiven. The old reset code
        // made debt == principal at the reset instant.
        (,, uint256 _principalAfter,,,, uint256 _debtAfter,,,) = gettersF.getLoanDetails(_loanId);
        assertGt(_principalAfter, 0, "loan still open");
        assertGt(_debtAfter, _principalAfter, "accrued interest on remaining principal retained");
    }

    function testLiquidateLoanWithNativeTokenCollateral_Success() public {
        createVaultAndFund(100e6);
        uint256 _positionId = depositCollateralFor(user1, address(1), 4 ether); // 4 tokens @ $1500 = $6000

        uint256 _borrowAmount = 10e6; // 10 tokens @ 250 = $2500
        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 365 days);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
        updatePricefeedsData();

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId); // 12 tokens = 12 * 250 = $3000

        // Make position liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(830e8); // collateral at $3600 (4 * 900) -> liquidation zone

        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _userCollateralBefore = gettersF.getPositionCollateral(_positionId, address(1));
        uint256 _t1BalanceBefore = liquidator.balance;
        uint256 _vaultBalanceBefore = token4.balanceOf(gettersF.getTokenVault(address(token4)));
        uint256 _vaultTotalAssetBefore = gettersF.getVaultTotalAssets(address(token4));

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
        assertEq(_vaultBalanceBefore + _debt, token4.balanceOf(gettersF.getTokenVault(address(token4))));
        assertEq(_vaultTotalAssetBefore, gettersF.getVaultTotalAssets(address(token4))); // should be equal because total assets adds debt loans
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

        defaultConfig.liquidationBonus = 1000;

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

    function testSendingMoreAmountThanDebtOnlyLiquidateTheDebtValue() public {
        protocolF.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        createVaultAndFund(100e6); // $250/token = $25,000
        // --- Setup: borrower has $10,000 collateral, takes loan close to liquidation threshold ---
        uint256 _positionId = depositCollateralFor(user1, address(token3), 10_000e6);
        vm.startPrank(user1);
        uint256 loanId = protocolF.takeLoan(address(token4), 20e6, 30 days);
        protocolF.takeLoan(address(token4), 10e6, 30 days); // drive position close to liquidation
        vm.stopPrank();

        // --- Fast-forward so position becomes liquidatable ---
        vm.warp(block.timestamp + 365 days);
        updatePricefeedsData();
        MockV3Aggregator(pricefeed3).updateAnswer(0.9e8);

        // Verify position is liquidatable
        assertTrue(liquidationF.isLiquidatable(_positionId));

        // Record balances before liquidation
        uint256 collateralBefore = gettersF.getPositionCollateral(_positionId, address(token3));
        uint256 loanDebt = gettersF.getOutstandingDebtForLoan(loanId);

        uint256 _liquidationAmount = 50e6;
        mintTokenTo(address(token4), liquidator, _liquidationAmount);
        // --- Exploit: liquidator passes type(uint256).max as _amount ---
        vm.startPrank(liquidator);
        token4.approve(address(diamond), _liquidationAmount);

        // The liquidator calls with a hugely inflated amount
        liquidationF.liquidateLoan(
            loanId,
            _liquidationAmount, // <-- uncapped, inflates collateral seizure
            address(token3)
        );
        vm.stopPrank();

        // --- Verify: borrower losses the collateral needed to pay off debt and liquidation bonus ---
        uint256 collateralAfter = gettersF.getPositionCollateral(_positionId, address(token3));

        // The liquidator receives collateral worth <= loanDebt + liquidationBonus
        uint256 _liquidatorBalance = token3.balanceOf(liquidator);
        (, uint256 _debtValue) = priceOracleF.getTokenValueInUSD(address(token4), loanDebt);
        (, uint256 _liquidatedValue) = priceOracleF.getTokenValueInUSD(address(token3), _liquidatorBalance);
        assertLt(collateralAfter, collateralBefore);
        assertLt(collateralAfter, collateralBefore);
        assertGe(_debtValue * 105 / 100, _liquidatedValue);
    }
}
