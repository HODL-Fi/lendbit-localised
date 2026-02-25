// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base, ERC20Mock} from "./Base.t.sol";
import {LendbitSpoke} from "../contracts/LendbitSpoke.sol";
import {console} from "forge-std/console.sol";

import "../contracts/models/Protocol.sol";
import "../contracts/models/Error.sol";
import "../contracts/models/Event.sol";

contract LendbitSpokeTest is Base {
    LendbitSpoke internal lendbitSpoke;

    function setUp() public override {
        lendbitSpoke = new LendbitSpoke();

        (address _token1, address _pricefeed1) = deployERC20ContractAndAddPriceFeed("token1", 18, 1500);
        (address _token2, address _pricefeed2) = deployERC20ContractAndAddPriceFeed("token2", 18, 300);
        (address _token3, address _pricefeed3) = deployERC20ContractAndAddPriceFeed("token3", 6, 1);
        (address _token4, address _pricefeed4) = deployERC20ContractAndAddPriceFeed("SupToken", 6, 250);

        token1 = ERC20Mock(_token1);
        token2 = ERC20Mock(_token2);
        token3 = ERC20Mock(_token3);
        token4 = ERC20Mock(_token4);

        pricefeed1 = _pricefeed1;
        pricefeed2 = _pricefeed2;
        pricefeed3 = _pricefeed3;
        pricefeed4 = _pricefeed4;

        // Setup initial collateral tokens
        _whitelistUserAddresses();
        _setupInitialCollateralTokens();
        lendbitSpoke.setInterestRate(2000, 500);
        lendbitSpoke.addSupportedToken(_token4, _pricefeed4);
        lendbitSpoke.setRequestSigner(requestSignerAddress);
    }

    // =============================================================
    //                    ADD COLLATERAL TOKEN TESTS
    // =============================================================

    function testAddCollateralToken() public {
        address newToken = address(0x123);

        vm.expectEmit(true, false, false, false);
        emit CollateralTokenAdded(newToken);
        vm.expectEmit(true, true, true, false);
        emit CollateralTokenLTVUpdated(newToken, 0, baseTokenLTV);
        lendbitSpoke.addCollateralToken(newToken, pricefeed1, baseTokenLTV);

        assertTrue(lendbitSpoke.isCollateralTokenSupported(newToken));

        address[] memory allTokens = lendbitSpoke.getAllCollateralTokens();
        bool found = false;
        for (uint256 i = 0; i < allTokens.length; i++) {
            if (allTokens[i] == newToken) {
                found = true;
                break;
            }
            assertEq(lendbitSpoke.getCollateralTokenLTV(allTokens[i]), baseTokenLTV);
        }
        assertTrue(found, "Token should be in collateral tokens array");
    }

    function testAddCollateralTokenFailsIfNotSecurityCouncil() public {
        address newToken = address(0x123);

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        lendbitSpoke.addCollateralToken(newToken, pricefeed1, baseTokenLTV);
        vm.stopPrank();
    }

    function testAddCollateralTokenFailsForAddressZero() public {
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        lendbitSpoke.addCollateralToken(address(0), address(0), baseTokenLTV);
    }

    function testAddCollateralTokenFailsForLTVBelow10Percent() public {
        address newToken = address(0x123);

        vm.expectRevert("LTV_BELOW_TEN_PERCENT()");
        lendbitSpoke.addCollateralToken(newToken, pricefeed1, 999);
    }

    function testAddCollateralTokenFailsIfAlreadySupported() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL.selector, address(token1)));
        lendbitSpoke.addCollateralToken(address(token1), pricefeed1, baseTokenLTV);
    }

    // =============================================================
    //                  REMOVE COLLATERAL TOKEN TESTS
    // =============================================================

    function testRemoveCollateralToken() public {
        assertTrue(lendbitSpoke.isCollateralTokenSupported(address(token1)));

        vm.expectEmit(true, false, false, false);
        emit CollateralTokenRemoved(address(token1));

        lendbitSpoke.removeCollateralToken(address(token1));

        assertFalse(lendbitSpoke.isCollateralTokenSupported(address(token1)));

        address[] memory allTokens = lendbitSpoke.getAllCollateralTokens();
        bool found = false;
        for (uint256 i = 0; i < allTokens.length; i++) {
            if (allTokens[i] == address(token1)) {
                found = true;
                break;
            }
        }
        assertFalse(found, "Token should be removed from collateral tokens array");
    }

    function testRemoveCollateralTokenFailsIfNotSecurityCouncil() public {
        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        lendbitSpoke.removeCollateralToken(address(token1));
        vm.stopPrank();
    }

    function testRemoveCollateralTokenFailsForAddressZero() public {
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        lendbitSpoke.removeCollateralToken(address(0));
    }

    function testRemoveCollateralTokenFailsIfNotSupported() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED_AS_COLLATERAL.selector, address(token3)));
        lendbitSpoke.removeCollateralToken(address(token3));
    }

    // =============================================================
    //                    DEPOSIT COLLATERAL TESTS
    // =============================================================

    function testDepositCollateral() public {
        uint256 depositAmount = 1000 * 1e18;

        // Mint tokens to user1
        token1.mint(user1, depositAmount);

        vm.startPrank(user1);

        // Approve spending
        token1.approve(address(lendbitSpoke), depositAmount);

        // Expect events
        vm.expectEmit(true, true, false, false);
        emit PositionIdCreated(1, user1);

        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(1, address(token1), depositAmount);

        // Deposit collateral
        lendbitSpoke.depositCollateral(address(token1), depositAmount);

        vm.stopPrank();

        // Verify collateral was deposited
        uint256 collateralBalance = lendbitSpoke.getPositionCollateral(1, address(token1));
        assertEq(collateralBalance, depositAmount);

        // Verify token was transferred
        assertEq(token1.balanceOf(user1), 0);
        assertEq(token1.balanceOf(address(lendbitSpoke)), depositAmount);

        // Verify position was created
        assertEq(lendbitSpoke.getPositionIdForUser(user1), 1);
    }

    function testDepositNativeTokenCollateral() public {
        uint256 depositAmount = 1000 * 1e18;
        vm.deal(user1, depositAmount);

        vm.startPrank(user1);

        // Expect events
        vm.expectEmit(true, true, false, false);
        emit PositionIdCreated(1, user1);

        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(1, address(1), depositAmount);

        // Deposit collateral
        lendbitSpoke.depositCollateral{value: depositAmount}(address(1), depositAmount);
        vm.stopPrank();

        // Verify collateral was deposited
        uint256 collateralBalance = lendbitSpoke.getPositionCollateral(1, address(1));
        assertEq(collateralBalance, depositAmount);

        // Verify token was transferred
        assertEq(user1.balance, 0);
        assertEq(address(lendbitSpoke).balance, depositAmount);

        // Verify position was created
        assertEq(lendbitSpoke.getPositionIdForUser(user1), 1);
    }

    function testDepositNativeTokenCollateralRevertWithDifferentMsgValueFromAmount() public {
        uint256 depositAmount = 1000 * 1e18;
        vm.deal(user1, depositAmount);

        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(AMOUNT_MISMATCH.selector, 1 ether, depositAmount));
        lendbitSpoke.depositCollateral{value: 1 ether}(address(1), depositAmount);
        vm.stopPrank();
    }

    function testDepositCollateralToExistingPosition() public {
        uint256 depositAmount1 = 1000 * 1e18;
        uint256 depositAmount2 = 500 * 1e18;

        // Create position first
        lendbitSpoke.createPositionFor(user1);
        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Mint tokens to user1
        token1.mint(user1, depositAmount1 + depositAmount2);

        vm.startPrank(user1);

        // First deposit
        token1.approve(address(lendbitSpoke), depositAmount1);
        lendbitSpoke.depositCollateral(address(token1), depositAmount1);

        // Second deposit
        token1.approve(address(lendbitSpoke), depositAmount2);

        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(positionId, address(token1), depositAmount2);

        lendbitSpoke.depositCollateral(address(token1), depositAmount2);

        vm.stopPrank();

        // Verify total collateral
        uint256 totalCollateral = lendbitSpoke.getPositionCollateral(positionId, address(token1));
        assertEq(totalCollateral, depositAmount1 + depositAmount2);
    }

    function testDepositCollateralFailsForAddressZero() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(0)));
        lendbitSpoke.depositCollateral(address(0), 1000);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        lendbitSpoke.depositCollateral(address(token1), 0);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForUnsupportedToken() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token3)));
        lendbitSpoke.depositCollateral(address(token3), 1000);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForInsufficientAllowance() public {
        uint256 depositAmount = 1000 * 1e18;
        token1.mint(user1, depositAmount);

        vm.startPrank(user1);
        // Don't approve or approve less than needed
        token1.approve(address(lendbitSpoke), depositAmount - 1);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ALLOWANCE.selector));
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForInsufficientBalance() public {
        uint256 depositAmount = 1000 * 1e18;
        token1.mint(user1, depositAmount - 1); // Mint less than needed

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();
    }

    function testSetCollateralTokenLTV() public {
        uint16 _newLTV = 5000; // 50%

        vm.expectEmit(true, true, true, false);
        emit CollateralTokenLTVUpdated(address(token1), baseTokenLTV, _newLTV);
        lendbitSpoke.setCollateralTokenLtv(address(token1), _newLTV);

        assertEq(_newLTV, lendbitSpoke.getCollateralTokenLTV(address(token1)));
    }

    function testSetCollateralTokenLTVFailsIfNotSecurityCouncil() public {
        uint16 _newLTV = 5000; // 50%

        vm.startPrank(user1);
        vm.expectRevert("ONLY_SECURITY_COUNCIL()");
        lendbitSpoke.setCollateralTokenLtv(address(token1), _newLTV);
    }

    function testSetCollateralTokenLTVFailsIfLTVBelow10Percent() public {
        uint16 _newLTV = 900; // 9%

        vm.expectRevert("LTV_BELOW_TEN_PERCENT()");
        lendbitSpoke.setCollateralTokenLtv(address(token1), _newLTV);
    }

    function testSetCollateralTokenLTVFailsForAddressZero() public {
        uint16 _newLTV = 1000; // 10%

        vm.expectRevert("ADDRESS_ZERO()");
        lendbitSpoke.setCollateralTokenLtv(address(0), _newLTV);
    }

    function testSetCollateralTokenLTVFailsIfTokenIsNotSupportedCollateral() public {
        uint16 _newLTV = 5000; // 50%
        address _unsupportedCollateral = address(0x123);

        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED_AS_COLLATERAL.selector, _unsupportedCollateral));
        lendbitSpoke.setCollateralTokenLtv(_unsupportedCollateral, _newLTV);
    }

    function testSetInterestRate() public {
        uint16 _newInterestRate = 5000; // 50%
        uint16 _newPenaltyRate = 1000; // 10%

        vm.expectEmit(true, true, true, false);
        emit InterestRateUpdated(_newInterestRate, _newPenaltyRate);
        lendbitSpoke.setInterestRate(_newInterestRate, _newPenaltyRate);

        (uint16 _interestBps, uint16 _penaltyBps) = lendbitSpoke.getInterestRate();
        assertEq(_newInterestRate, _interestBps);
        assertEq(_newPenaltyRate, _penaltyBps);
    }

    function testSetInterestRateFailsIfNotSecurityCouncil() public {
        uint16 _newInterestRate = 5000; // 50%
        uint16 _newPenaltyRate = 1000; // 10%

        vm.startPrank(user1);
        vm.expectRevert("ONLY_SECURITY_COUNCIL()");
        lendbitSpoke.setInterestRate(_newInterestRate, _newPenaltyRate);
    }

    function testSetInterestRateFailsIfRateIs0Percent() public {
        uint16 _newInterestRate = 0;
        uint16 _newPenaltyRate = 1000; // 10%

        vm.expectRevert("AMOUNT_ZERO()");
        lendbitSpoke.setInterestRate(_newInterestRate, _newPenaltyRate);
    }

    // =============================================================
    //                   WITHDRAW COLLATERAL TESTS
    // =============================================================

    function testWithdrawCollateral() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 300 * 1e18;

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Verify initial collateral balance
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), depositAmount);
        assertEq(token1.balanceOf(user1), 0);
        assertEq(token1.balanceOf(address(lendbitSpoke)), depositAmount);

        // Withdraw some collateral
        vm.expectEmit(true, true, true, false);
        emit CollateralWithdrawn(positionId, address(token1), withdrawAmount);
        lendbitSpoke.withdrawCollateral(address(token1), withdrawAmount);
        vm.stopPrank();

        // Verify collateral was withdrawn
        uint256 remainingCollateral = depositAmount - withdrawAmount;
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), remainingCollateral);
        assertEq(token1.balanceOf(user1), withdrawAmount);
        assertEq(token1.balanceOf(address(lendbitSpoke)), remainingCollateral);
    }

    function testWithdrawNativeTokenCollateral() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 300 * 1e18;

        // First deposit some collateral
        vm.deal(user1, depositAmount);
        vm.startPrank(user1);
        lendbitSpoke.depositCollateral{value: depositAmount}(address(1), depositAmount);

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Withdraw some collateral
        vm.expectEmit(true, true, true, false);
        emit CollateralWithdrawn(positionId, address(1), withdrawAmount);

        lendbitSpoke.withdrawCollateral(address(1), withdrawAmount);
        vm.stopPrank();

        // Verify collateral was withdrawn
        uint256 remainingCollateral = depositAmount - withdrawAmount;
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(1)), remainingCollateral);
        assertEq(user1.balance, withdrawAmount);
        assertEq(address(lendbitSpoke).balance, remainingCollateral);
    }

    function testWithdrawAllCollateral() public {
        uint256 depositAmount = 1000 * 1e18;

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Withdraw all collateral
        vm.expectEmit(true, true, true, false);
        emit CollateralWithdrawn(positionId, address(token1), depositAmount);

        lendbitSpoke.withdrawCollateral(address(token1), depositAmount);
        vm.stopPrank();

        // Verify all collateral was withdrawn
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), 0);
        assertEq(token1.balanceOf(user1), depositAmount);
        assertEq(token1.balanceOf(address(lendbitSpoke)), 0);
    }

    function testWithdrawCollateralMultipleTokens() public {
        uint256 depositAmount1 = 1000 * 1e18;
        uint256 depositAmount2 = 2000 * 1e18;
        uint256 withdrawAmount1 = 500 * 1e18;
        uint256 withdrawAmount2 = 1000 * 1e18;

        // Deposit two different tokens
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount1);
        token2.approve(address(lendbitSpoke), depositAmount2);

        lendbitSpoke.depositCollateral(address(token1), depositAmount1);
        lendbitSpoke.depositCollateral(address(token2), depositAmount2);

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Withdraw from both tokens
        lendbitSpoke.withdrawCollateral(address(token1), withdrawAmount1);
        lendbitSpoke.withdrawCollateral(address(token2), withdrawAmount2);
        vm.stopPrank();

        // Verify withdrawals
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), depositAmount1 - withdrawAmount1);
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token2)), depositAmount2 - withdrawAmount2);
        assertEq(token1.balanceOf(user1), withdrawAmount1);
        assertEq(token2.balanceOf(user1), withdrawAmount2);
    }

    function testWithdrawCollateralFailsIfNoPosition() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user1));
        lendbitSpoke.withdrawCollateral(address(token1), 1000);
        vm.stopPrank();
    }

    function testWithdrawCollateralFailsForInsufficientBalance() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 1500 * 1e18; // More than deposited

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);

        // Try to withdraw more than available
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        lendbitSpoke.withdrawCollateral(address(token1), withdrawAmount);
        vm.stopPrank();
    }

    function testWithdrawCollateralFailsForZeroAmount() public {
        uint256 depositAmount = 1000 * 1e18;

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);

        // Try to withdraw zero amount - this should fail at the LibProtocol level
        // Note: The current implementation doesn't have zero amount check in withdraw
        // but we can test withdrawing 0 should leave balances unchanged
        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);
        uint256 initialBalance = lendbitSpoke.getPositionCollateral(positionId, address(token1));
        uint256 initialUserBalance = token1.balanceOf(user1);

        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        lendbitSpoke.withdrawCollateral(address(token1), 0);

        // Balances should remain unchanged
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), initialBalance);
        assertEq(token1.balanceOf(user1), initialUserBalance);
        vm.stopPrank();
    }

    function testWithdrawCollateralFromEmptyBalance() public {
        uint256 depositAmount = 1000 * 1e18;

        // Deposit and then withdraw all
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        lendbitSpoke.withdrawCollateral(address(token1), depositAmount);

        // Try to withdraw again from empty balance
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        lendbitSpoke.withdrawCollateral(address(token1), 1);
        vm.stopPrank();
    }

    function testWithdrawCollateralDifferentTokensIndependently() public {
        uint256 depositAmount = 1000 * 1e18;

        // Deposit token1 only
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Should be able to withdraw token1
        lendbitSpoke.withdrawCollateral(address(token1), 500 * 1e18);

        // Should fail to withdraw token2 (no balance)
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        lendbitSpoke.withdrawCollateral(address(token2), 1);

        // Verify token1 balance is correct and token2 balance is still 0
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), 500 * 1e18);
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token2)), 0);
        vm.stopPrank();
    }

    function testWithdrawCollateralMultipleUsers() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 300 * 1e18;

        // Both users deposit
        token1.mint(user1, depositAmount);
        token1.mint(user2, depositAmount);

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 user1PositionId = lendbitSpoke.getPositionIdForUser(user1);
        uint256 user2PositionId = lendbitSpoke.getPositionIdForUser(user2);

        // User1 withdraws
        vm.startPrank(user1);
        lendbitSpoke.withdrawCollateral(address(token1), withdrawAmount);
        vm.stopPrank();

        // Verify only user1's collateral was affected
        assertEq(lendbitSpoke.getPositionCollateral(user1PositionId, address(token1)), depositAmount - withdrawAmount);
        assertEq(lendbitSpoke.getPositionCollateral(user2PositionId, address(token1)), depositAmount);
        assertEq(token1.balanceOf(user1), withdrawAmount);
        assertEq(token1.balanceOf(user2), 0);
        assertEq(token1.balanceOf(address(lendbitSpoke)), depositAmount * 2 - withdrawAmount);
    }

    function testWithdrawCollateralPartialAmounts() public {
        uint256 depositAmount = 1000 * 1e18;

        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Multiple partial withdrawals
        lendbitSpoke.withdrawCollateral(address(token1), 100 * 1e18);
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), 900 * 1e18);
        assertEq(token1.balanceOf(user1), 100 * 1e18);

        lendbitSpoke.withdrawCollateral(address(token1), 200 * 1e18);
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), 700 * 1e18);
        assertEq(token1.balanceOf(user1), 300 * 1e18);

        lendbitSpoke.withdrawCollateral(address(token1), 700 * 1e18); // Withdraw remaining
        assertEq(lendbitSpoke.getPositionCollateral(positionId, address(token1)), 0);
        assertEq(token1.balanceOf(user1), 1000 * 1e18);

        vm.stopPrank();
    }

    // =============================================================
    //                  TAKE TENURED LOAN TESTS
    // =============================================================
    function testTakeLoan() public {
        // createVaultAndFund(1000000e18);
        uint256 _collateralAmount = 10000 * 1e18; // $15M worth of token1 (10k * $1500)
        uint256 _borrowAmount = 1000 * 1e6; // $250k worth of token4 (1k * $250)
        uint256 _tenure = 365 days;

        // Deposit collateral first
        token1.mint(user1, _collateralAmount);

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), _collateralAmount);
        lendbitSpoke.depositCollateral(address(token1), _collateralAmount);

        uint256 _positionId = lendbitSpoke.getPositionIdForUser(user1);
        uint256 _healthFactor = lendbitSpoke.getHealthFactor(_positionId, 0);

        uint256 loanId = lendbitSpoke.takeLoan(address(token4), _borrowAmount, _tenure);
        uint256 totalDebt = lendbitSpoke.getTotalActiveDebt(_positionId);
        vm.stopPrank();

        assertEq(loanId, 1, "Loan ID should be 1 for the first loan");
        assertLt(lendbitSpoke.getHealthFactor(_positionId, 0), _healthFactor);
        assertEq(totalDebt, 250000e18);
    }

    function testTakeLoanFailsWithoutPosition() public {
        uint256 borrowAmount = 1000 * 1e18;

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user1));
        lendbitSpoke.takeLoan(address(token1), borrowAmount, 30 days);
        vm.stopPrank();
    }

    function testTakeLoanFailsForUnsupportedToken() public {
        // Create position first
        lendbitSpoke.createPositionFor(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token3)));
        lendbitSpoke.takeLoan(address(token3), 1000 * 1e18, 30 days);
        vm.stopPrank();
    }

    function testRepayLoanSuccess() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = lendbitSpoke.takeLoan(address(token4), borrowAmount, 365 days);

        vm.warp(block.timestamp + (365 days / 2)); // Warp half the tenure to accrue some interest

        uint256 _debtBeforeRepay = lendbitSpoke.getOutstandingDebtForLoan(_loanId);

        uint256 remainingDebt = executeRepayLoan(_loanId, _debtBeforeRepay);

        assertEq(remainingDebt, 0, "Debt should be zero after full repayment");
        assertEq(lendbitSpoke.getOutstandingDebtForLoan(_loanId), 0, "Outstanding debt should be cleared");

        (,,, uint256 repaid,,,,,, uint8 status) = lendbitSpoke.getLoanDetails(_loanId);
        assertEq(repaid, _debtBeforeRepay, "Repayment amount should match outstanding debt");
        assertEq(status, uint8(LoanStatus.REPAID), "Loan should be marked repaid");
        vm.stopPrank();
    }

    function testRepayLoanPartial() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = lendbitSpoke.takeLoan(address(token4), borrowAmount, 30 days);
        vm.warp(block.timestamp + 15 days); // Warp half the tenure to accrue some interest

        uint256 partialRepay = borrowAmount;
        uint256 remainingDebt = executeRepayLoan(_loanId, partialRepay);

        assertGt(remainingDebt, 0, "Debt should remain after partial repayment");
        assertLt(remainingDebt, borrowAmount, "Debt should be less than initial borrow");

        (,,, uint256 repaid,,,,,, uint8 status) = lendbitSpoke.getLoanDetails(_loanId);
        assertEq(repaid, partialRepay, "Partial repayment should be tracked");
        assertEq(status, uint8(LoanStatus.FULFILLED), "Loan should remain active after partial repay");
        vm.stopPrank();
    }

    function testRepayLoanFailsForInvalidSignature() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = lendbitSpoke.takeLoan(address(token4), borrowAmount, 30 days);

        RepayRequest memory request = createRepayRequest(_loanId, borrowAmount);
        uint256 invalidKey = REQUEST_SIGNER_PRIVATE_KEY + 1;
        address invalidSigner = vm.addr(invalidKey);
        bytes memory invalidSignature = signRepayRequestWithKey(request, invalidKey);

        vm.expectRevert(abi.encodeWithSelector(REQUEST_INVALID_SIGNATURE.selector, invalidSigner));
        lendbitSpoke.repayLoan(request, invalidSignature);
        vm.stopPrank();
    }

    function testRepayLoanFailsForTargetChainMismatch() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = lendbitSpoke.takeLoan(address(token4), borrowAmount, 365 days);

        RepayRequest memory request = createRepayRequest(_loanId, borrowAmount);
        request.targetChainId = block.chainid + 1;
        bytes memory signature = signRepayRequestWithKey(request, REQUEST_SIGNER_PRIVATE_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(REQUEST_REPAY_TARGET_CHAIN_MISMATCH.selector, block.chainid, request.targetChainId)
        );
        lendbitSpoke.repayLoan(request, signature);
        vm.stopPrank();
    }

    function testRepayLoanMoreThanDebt() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = lendbitSpoke.takeLoan(address(token4), borrowAmount, 365 days);

        vm.warp(block.timestamp + 30 days); // Warp to accrue some interest

        uint256 debtBeforeRepay = lendbitSpoke.getOutstandingDebtForLoan(_loanId);
        uint256 remainingDebt = executeRepayLoan(_loanId, borrowAmount * 2);

        assertEq(remainingDebt, 0, "Debt should be zero after over-repayment");

        (,,, uint256 repaid,,,,,, uint8 status) = lendbitSpoke.getLoanDetails(_loanId);
        assertEq(repaid, debtBeforeRepay, "Repayment should be capped at outstanding debt");
        assertEq(status, uint8(LoanStatus.REPAID), "Loan should be marked repaid");
        vm.stopPrank();
    }

    function testRepayLoanFailsIfSenderIsNotOwnerOfLoan() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);
        uint256 _positionId = depositCollateralFor(user2, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = lendbitSpoke.takeLoan(address(token4), borrowAmount, 365 days);
        vm.stopPrank();

        // Attempt to repay from a different user
        vm.startPrank(user2);
        token4.mint(user2, borrowAmount);
        token4.approve(address(lendbitSpoke), borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(NOT_LOAN_OWNER.selector, _positionId));
        executeRepayLoan(_loanId, borrowAmount);
        vm.stopPrank();
    }

    // =============================================================
    //                       VALUE CALCULATION TESTS
    // =============================================================
    function testGetHealthFactorWithBorrows() public {
        uint256 depositAmount = 1000 * 1e18; // $1.5M collateral
        uint256 currentBorrowValue = 500000 * 1e18; // $500k borrow

        // Create position with collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Calculate health factor
        uint256 healthFactor = lendbitSpoke.getHealthFactor(positionId, currentBorrowValue);

        // Expected: (1.5M * 0.8) / 0.5M = 2.4
        uint256 collateralValue = 1000 * 1500 * 1e18;
        uint256 adjustedCollateralValue = (collateralValue * 8000) / 10000;
        uint256 expectedHealthFactor = (adjustedCollateralValue * 1e18) / currentBorrowValue;

        assertEq(healthFactor, expectedHealthFactor, "Health factor calculation should be correct");
    }

    function testGetHealthFactorEdgeCases() public {
        // Test with zero collateral and zero borrow
        lendbitSpoke.createPositionFor(user1);
        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // With zero collateral and zero additional borrow, should return 0
        uint256 healthFactor = lendbitSpoke.getHealthFactor(positionId, 0);
        assertEq(healthFactor, 0, "Zero collateral with zero borrow should return 0");

        // With zero collateral and some borrow, should return 0
        uint256 healthFactorWithBorrow = lendbitSpoke.getHealthFactor(positionId, 1000 * 1e18);
        assertEq(healthFactorWithBorrow, 0, "Zero collateral with borrow should return 0");
    }

    // =============================================================
    //              INTEGRATION TESTS WITH MULTIPLE FUNCTIONS
    // =============================================================

    function testCompleteCollateralAndValueFlow() public {
        uint256 depositAmount1 = 500 * 1e18; // 500 token1 @ $1500 = $750k
        uint256 depositAmount2 = 1000 * 1e18; // 1000 token2 @ $300 = $300k

        // Setup collateral
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount1);
        token2.approve(address(lendbitSpoke), depositAmount2);

        lendbitSpoke.depositCollateral(address(token1), depositAmount1);
        lendbitSpoke.depositCollateral(address(token2), depositAmount2);
        vm.stopPrank();

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Test individual token values
        (, uint256 token1Value) = lendbitSpoke.getTokenValueInUSD(address(token1), depositAmount1);
        (, uint256 token2Value) = lendbitSpoke.getTokenValueInUSD(address(token2), depositAmount2);

        assertEq(token1Value, 500 * 1500 * 1e18, "Token1 value should be correct");
        assertEq(token2Value, 1000 * 300 * 1e18, "Token2 value should be correct");

        // Test total collateral value
        uint256 totalCollateralValue = lendbitSpoke.getPositionCollateralValue(positionId);
        assertEq(totalCollateralValue, token1Value + token2Value, "Total collateral should sum individual values");

        // Test borrowed value (should be 0)
        uint256 borrowedValue = lendbitSpoke.getTotalActiveDebt(positionId);
        assertEq(borrowedValue, 0, "Borrowed value should be 0");

        // Test health factor with hypothetical borrow
        uint256 hypotheticalBorrow = 200000 * 1e18; // $200k
        uint256 healthFactor = lendbitSpoke.getHealthFactor(positionId, hypotheticalBorrow);

        // Expected: ((750k + 300k) * 0.8) / 200k = 4.2
        uint256 expectedHealthFactor = (totalCollateralValue * 8000 * 1e18 / 10000) / hypotheticalBorrow;
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be calculated correctly");
    }

    // =============================================================
    //                       VALUE CALCULATION TESTS
    // =============================================================
    function testGetPositionCollateralValueEmptyPosition() public {
        // Create empty position
        lendbitSpoke.createPositionFor(user1);
        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Should return 0 for empty position
        uint256 value = lendbitSpoke.getPositionCollateralValue(positionId);
        assertEq(value, 0);
    }

    function testGetPositionBorrowedValue() public {
        // Create a position
        lendbitSpoke.createPositionFor(user1);
        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Should return 0 for new position with no borrows
        uint256 value = lendbitSpoke.getTotalActiveDebt(positionId);
        assertEq(value, 0);
    }

    function testGetHealthFactorWithNoBorrows() public {
        // Create a position with collateral
        uint256 depositAmount = 1000 * 1e18;
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Health factor should be max (type(uint256).max) when no borrows
        uint256 healthFactor = lendbitSpoke.getHealthFactor(positionId, 0);
        assertEq(healthFactor, 12e41);
    }

    function testGetHealthFactorWithCurrentBorrowValue() public {
        uint256 currentBorrowValue = 500 * 1e18; // $500 worth of borrow
        uint256 positionId = depositCollateralFor(user1, address(token1), (1 * 1e18));

        // With collateral value 0 and borrow value > 0, health factor calculation
        // will depend on the actual collateral value from price feeds
        // This will likely revert or return 0 without proper price feeds
        uint256 _healthFactor = lendbitSpoke.getHealthFactor(positionId, currentBorrowValue);
        assertEq(_healthFactor, 2.4e18);

        // 100% collateral value
        _healthFactor = lendbitSpoke.getHealthFactor(positionId, 1500e18);
        assertEq(_healthFactor, 0.8e18);

        // 80% liquidation threshold
        _healthFactor = lendbitSpoke.getHealthFactor(positionId, 1200e18);
        assertEq(_healthFactor, 1e18);
    }

    // =============================================================
    //                       VIEW FUNCTION TESTS
    // =============================================================

    function testIsCollateralTokenSupported() public view {
        assertTrue(lendbitSpoke.isCollateralTokenSupported(address(token1)));
        assertTrue(lendbitSpoke.isCollateralTokenSupported(address(token2)));
        assertFalse(lendbitSpoke.isCollateralTokenSupported(address(token3)));
        assertFalse(lendbitSpoke.isCollateralTokenSupported(address(0x999)));
    }

    function testGetAllCollateralTokens() public view {
        address[] memory tokens = lendbitSpoke.getAllCollateralTokens();

        assertEq(tokens.length, 3);
        assertTrue(tokens[0] == address(token1) || tokens[1] == address(token1));
        assertTrue(tokens[0] == address(token2) || tokens[1] == address(token2));
    }

    function testGetAllCollateralTokensAfterAddingAndRemoving() public {
        // Add a new token
        lendbitSpoke.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);

        address[] memory tokens = lendbitSpoke.getAllCollateralTokens();
        assertEq(tokens.length, 4);

        // Remove a token
        lendbitSpoke.removeCollateralToken(address(token1));

        tokens = lendbitSpoke.getAllCollateralTokens();
        assertEq(tokens.length, 3);

        // Verify token1 is not in the array
        for (uint256 i = 0; i < tokens.length; i++) {
            assertTrue(tokens[i] != address(token1));
        }
    }

    function testGetPositionCollateral() public {
        uint256 depositAmount = 1000 * 1e18;

        // Initially should be 0
        assertEq(lendbitSpoke.getPositionCollateral(1, address(token1)), 0);

        // Deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount);
        lendbitSpoke.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        // Should now return the deposited amount
        assertEq(lendbitSpoke.getPositionCollateral(1, address(token1)), depositAmount);

        // Other tokens should still be 0
        assertEq(lendbitSpoke.getPositionCollateral(1, address(token2)), 0);
        assertEq(lendbitSpoke.getPositionCollateral(2, address(token1)), 0);
    }

    function testMultipleUsersAndTokens() public {
        uint256 user1Amount = 1000 * 1e18;
        uint256 user2Amount = 2000 * 1e18;

        // Setup tokens for users
        token1.mint(user1, user1Amount);
        token2.mint(user1, user1Amount);
        token1.mint(user2, user2Amount);
        token2.mint(user2, user2Amount);

        // User1 deposits
        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), user1Amount);
        token2.approve(address(lendbitSpoke), user1Amount);
        lendbitSpoke.depositCollateral(address(token1), user1Amount);
        lendbitSpoke.depositCollateral(address(token2), user1Amount / 2);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        token1.approve(address(lendbitSpoke), user2Amount);
        lendbitSpoke.depositCollateral(address(token1), user2Amount);
        vm.stopPrank();

        uint256 user1PositionId = lendbitSpoke.getPositionIdForUser(user1);
        uint256 user2PositionId = lendbitSpoke.getPositionIdForUser(user2);

        // Verify individual collateral amounts
        assertEq(lendbitSpoke.getPositionCollateral(user1PositionId, address(token1)), user1Amount);
        assertEq(lendbitSpoke.getPositionCollateral(user1PositionId, address(token2)), user1Amount / 2);
        assertEq(lendbitSpoke.getPositionCollateral(user2PositionId, address(token1)), user2Amount);
        assertEq(lendbitSpoke.getPositionCollateral(user2PositionId, address(token2)), 0);
    }

    function testGetPositionCollateralValue() public {
        lendbitSpoke.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        uint256 depositAmount1 = 2 * 1e18; // 2 tokens of token1 (18 decimals)
        uint256 depositAmount2 = 10 * 1e18; // 10 tokens of token2 (18 decimals)
        uint256 depositAmount3 = 1000 * 1e6; // 1000 tokens of token3 (6 decimals)

        // Deposit collateral
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);
        token3.mint(user1, depositAmount3);

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount1);
        token2.approve(address(lendbitSpoke), depositAmount2);
        token3.approve(address(lendbitSpoke), depositAmount3);

        lendbitSpoke.depositCollateral(address(token1), depositAmount1);
        lendbitSpoke.depositCollateral(address(token2), depositAmount2);
        lendbitSpoke.depositCollateral(address(token3), depositAmount3);
        vm.stopPrank();

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Calculate expected value
        // token1: 2 * $1500 = $3000
        // token2: 10 * $300 = $3000
        // token3: 1000 * $1 = $1000
        // Total = $7000
        uint256 expectedValue = 7000 * 1e18; // the value is returned with 18 decimals

        uint256 collateralValue = lendbitSpoke.getPositionCollateralValue(positionId);
        assertEq(collateralValue, expectedValue);
    }

    function testGetPositionBorrowableCollateralValue() public {
        lendbitSpoke.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        uint256 depositAmount1 = 2 * 1e18; // 2 tokens of token1 (18 decimals)
        uint256 depositAmount2 = 10 * 1e18; // 10 tokens of token2 (18 decimals)
        uint256 depositAmount3 = 1000 * 1e6; // 1000 tokens of token3 (6 decimals)

        // Deposit collateral
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);
        token3.mint(user1, depositAmount3);

        lendbitSpoke.setCollateralTokenLtv(address(token2), 5000); // set to 50%
        lendbitSpoke.setCollateralTokenLtv(address(token3), 5000); // set to 50%

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount1);
        token2.approve(address(lendbitSpoke), depositAmount2);
        token3.approve(address(lendbitSpoke), depositAmount3);

        lendbitSpoke.depositCollateral(address(token1), depositAmount1);
        lendbitSpoke.depositCollateral(address(token2), depositAmount2);
        lendbitSpoke.depositCollateral(address(token3), depositAmount3);
        vm.stopPrank();

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);

        // Calculate expected value
        // token1: 2 * $1500 * 0.8 = $2400
        // token2: 10 * $300 * 0.5 = $1500
        // token3: 1000 * $1 * 0.5 = $500
        // Total = $4400
        uint256 expectedValue = 4400 * 1e18; // the value is returned with 18 decimals

        uint256 collateralValue = lendbitSpoke.getPositionBorrowableCollateralValue(positionId);
        assertEq(collateralValue, expectedValue);
    }

    function testGetPositionBorrowableCollateralValueReducesWithActiveLoans() public {
        // createVaultAndFund(1000000e18);
        lendbitSpoke.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        uint256 depositAmount1 = 2 * 1e18; // 2 tokens of token1 (18 decimals)
        uint256 depositAmount2 = 10 * 1e18; // 10 tokens of token2 (18 decimals)
        uint256 depositAmount3 = 1000 * 1e6; // 1000 tokens of token3 (6 decimals)
        uint256 borrowAmount = 10 * 1e6;

        // Deposit collateral
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);
        token3.mint(user1, depositAmount3);

        lendbitSpoke.setCollateralTokenLtv(address(token2), 5000); // set to 50%
        lendbitSpoke.setCollateralTokenLtv(address(token3), 5000); // set to 50%

        vm.startPrank(user1);
        token1.approve(address(lendbitSpoke), depositAmount1);
        token2.approve(address(lendbitSpoke), depositAmount2);
        token3.approve(address(lendbitSpoke), depositAmount3);

        lendbitSpoke.depositCollateral(address(token1), depositAmount1);
        lendbitSpoke.depositCollateral(address(token2), depositAmount2);
        lendbitSpoke.depositCollateral(address(token3), depositAmount3);

        lendbitSpoke.takeLoan(address(token4), borrowAmount, 365 days);
        vm.stopPrank();

        uint256 positionId = lendbitSpoke.getPositionIdForUser(user1);
        (, uint256 borrowValue) = lendbitSpoke.getTokenValueInUSD(address(token4), borrowAmount);

        // Calculate expected value
        // token1: 2 * $1500 * 0.8 = $2400
        // token2: 10 * $300 * 0.5 = $1500
        // token3: 1000 * $1 * 0.5 = $500
        // Total = $4400
        uint256 expectedValue = 4400 * 1e18;

        assertEq((expectedValue - borrowValue), lendbitSpoke.getPositionBorrowableCollateralValue(positionId));
        assertEq(expectedValue, lendbitSpoke.getPositionUtilizableCollateralValue(positionId));
    }

    function testGetUserActiveLoanIds() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount1 = 1000 * 1e6;
        uint256 borrowAmount2 = 2000 * 1e6;

        uint256 _positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 loanId1 = lendbitSpoke.takeLoan(address(token4), borrowAmount1, 365 days);
        uint256 loanId2 = lendbitSpoke.takeLoan(address(token4), borrowAmount2, 365 days);
        vm.stopPrank();

        uint256[] memory activeLoanIds = lendbitSpoke.getUserActiveLoanIds(_positionId);

        assertEq(activeLoanIds.length, 2, "User should have 2 active loans");
        assertEq(activeLoanIds[0], loanId1, "First loan ID should match");
        assertEq(activeLoanIds[1], loanId2, "Second loan ID should match");
    }

    function testGetActiveLoanIds() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount1 = 1000 * 1e6;
        uint256 borrowAmount2 = 2000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);
        depositCollateralFor(user2, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 loanId1 = lendbitSpoke.takeLoan(address(token4), borrowAmount1, 365 days);
        uint256 loanId2 = lendbitSpoke.takeLoan(address(token4), borrowAmount2, 365 days);
        token4.approve(address(lendbitSpoke), borrowAmount1);
        executeRepayLoan(loanId1, borrowAmount1);
        // lendbitSpoke.repayLoan(loanId1, borrowAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 loanId3 = lendbitSpoke.takeLoan(address(token4), borrowAmount1, 365 days);
        uint256 loanId4 = lendbitSpoke.takeLoan(address(token4), borrowAmount2, 365 days);
        uint256 loanId5 = lendbitSpoke.takeLoan(address(token4), borrowAmount1, 365 days);

        token4.approve(address(lendbitSpoke), borrowAmount2);
        executeRepayLoan(loanId4, borrowAmount2);
        // lendbitSpoke.repayLoan(loanId4, borrowAmount2);
        vm.stopPrank();

        uint256[] memory activeLoanIds = lendbitSpoke.getActiveLoanIds();

        assertEq(activeLoanIds.length, 3, "should have 3 active loans");
        assertEq(activeLoanIds[0], loanId2, "First loan ID should match");
        assertEq(activeLoanIds[1], loanId3, "Second loan ID should match");
        assertEq(activeLoanIds[2], loanId5, "Third loan ID should match");
    }

    function testGetLoanDetails() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;
        uint256 tenure = 365 days;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 loanId = lendbitSpoke.takeLoan(address(token4), borrowAmount, tenure);
        token4.approve(address(lendbitSpoke), borrowAmount / 2);
        // lendbitSpoke.repayLoan(loanId, borrowAmount / 2);
        executeRepayLoan(loanId, borrowAmount / 2);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);

        (
            uint256 positionId,
            address token,
            uint256 principal,
            uint256 repaid,
            uint256 tenureSeconds,
            uint256 startTimestamp,
            uint256 debt,
            uint16 annualRateBps,
            uint16 penaltyRateBps,
            uint8 status
        ) = lendbitSpoke.getLoanDetails(loanId);

        assertEq(positionId, 1, "Position ID should match");
        assertEq(token, address(token4), "Loan token address should match");
        assertEq(principal, borrowAmount, "Principal amount should match");
        assertEq(
            debt,
            (borrowAmount * 20 / 200) + (borrowAmount / 2),
            "debt amount should have increased by 20% of outstanding principal after repay"
        );
        assertEq(repaid, borrowAmount / 2, "Repaid amount should match");
        assertEq(startTimestamp, (block.timestamp - 365 days), "Start time should match");
        assertEq(tenureSeconds, tenure, "End time should match");
        assertEq(annualRateBps, 2000, "Interest rate should match");
        assertEq(penaltyRateBps, 500, "Penalty rate should match");
        assertEq(status, uint8(LoanStatus.FULFILLED), "Loan should not be marked as repaid");
    }

    function testWithdrawCollateralAboveLTVWithActiveBorrowFails() public {
        // createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        lendbitSpoke.takeLoan(address(token4), borrowAmount, 90 days);

        // Attempt to withdraw collateral that would breach LTV
        vm.expectRevert(abi.encodeWithSelector(HEALTH_FACTOR_TOO_LOW.selector, 0));
        lendbitSpoke.withdrawCollateral(address(token1), collateralAmount);
        vm.stopPrank();
    }

    function depositCollateralFor(address _user, address _token, uint256 _amount)
        internal
        override
        returns (uint256 positionId)
    {
        if (_token == address(1)) {
            vm.deal(_user, _amount);
        } else {
            token1.mint(_user, _amount);
        }
        vm.startPrank(_user);
        if (_token == address(1)) {
            lendbitSpoke.depositCollateral{value: _amount}(_token, _amount);
        } else {
            ERC20Mock(_token).approve(address(lendbitSpoke), _amount);
            lendbitSpoke.depositCollateral(_token, _amount);
        }
        vm.stopPrank();
        positionId = lendbitSpoke.getPositionIdForUser(_user);
    }

    function executeRepayLoan(uint256 _loanId, uint256 _amount) internal override returns (uint256) {
        (RepayRequest memory request, bytes memory signature) = buildRepayRequest(_loanId, _amount);
        return lendbitSpoke.repayLoan(request, signature);
    }

    function createRepayRequest(uint256 _loanId, uint256 _amount)
        internal
        override
        returns (RepayRequest memory request)
    {
        request = RepayRequest({
            action: REPAY_ACTION,
            loanId: _loanId,
            amount: _amount,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: ++repayRequestNonce,
            contractAddress: address(lendbitSpoke)
        });
    }

    function _whitelistUserAddresses() internal {
        lendbitSpoke.whitelistAddress(address(this));
        lendbitSpoke.whitelistAddress(user1);
        lendbitSpoke.whitelistAddress(user2);
        lendbitSpoke.whitelistAddress(nonAdmin);
    }

    function _setupInitialCollateralTokens() internal override {
        lendbitSpoke.addCollateralToken(address(token1), pricefeed1, baseTokenLTV);
        lendbitSpoke.addCollateralToken(address(token2), pricefeed2, baseTokenLTV);
        lendbitSpoke.addCollateralToken(address(1), pricefeed1, baseTokenLTV); // Native token
    }
}
