// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/PriceOracleFacet.sol";
import "../contracts/facets/ProtocolFacet.sol";
import "../contracts/facets/PositionManagerFacet.sol";
import "../contracts/facets/VaultManagerFacet.sol";
import "../contracts/Diamond.sol";

import "../contracts/models/Protocol.sol";
import "../contracts/models/Error.sol";
import "../contracts/models/Event.sol";
import {Base} from "./Base.t.sol";
import {TokenVault} from "../contracts/TokenVault.sol";

contract ProtocolTest is Base {
    function setUp() public override {
        super.setUp();
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
        protocolF.addCollateralToken(newToken, pricefeed1, baseTokenLTV);

        assertTrue(gettersF.isCollateralTokenSupported(newToken));

        address[] memory allTokens = gettersF.getAllCollateralTokens();
        bool found = false;
        for (uint256 i = 0; i < allTokens.length; i++) {
            if (allTokens[i] == newToken) {
                found = true;
                break;
            }
            assertEq(gettersF.getCollateralTokenLTV(allTokens[i]), baseTokenLTV);
        }
        assertTrue(found, "Token should be in collateral tokens array");
    }

    function testAddCollateralTokenFailsIfNotSecurityCouncil() public {
        address newToken = address(0x123);

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        protocolF.addCollateralToken(newToken, pricefeed1, baseTokenLTV);
        vm.stopPrank();
    }

    function testAddCollateralTokenFailsForAddressZero() public {
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        protocolF.addCollateralToken(address(0), address(0), baseTokenLTV);
    }

    function testAddCollateralTokenFailsForLTVBelow10Percent() public {
        address newToken = address(0x123);

        vm.expectRevert("LTV_BELOW_TEN_PERCENT()");
        protocolF.addCollateralToken(newToken, pricefeed1, 999);
    }

    function testAddCollateralTokenFailsIfAlreadySupported() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL.selector, address(token1)));
        protocolF.addCollateralToken(address(token1), pricefeed1, baseTokenLTV);
    }

    // =============================================================
    //                  REMOVE COLLATERAL TOKEN TESTS
    // =============================================================

    function testRemoveCollateralToken() public {
        assertTrue(gettersF.isCollateralTokenSupported(address(token1)));

        vm.expectEmit(true, false, false, false);
        emit CollateralTokenRemoved(address(token1));

        protocolF.removeCollateralToken(address(token1));

        assertFalse(gettersF.isCollateralTokenSupported(address(token1)));

        address[] memory allTokens = gettersF.getAllCollateralTokens();
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
        protocolF.removeCollateralToken(address(token1));
        vm.stopPrank();
    }

    function testRemoveCollateralTokenFailsForAddressZero() public {
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        protocolF.removeCollateralToken(address(0));
    }

    function testRemoveCollateralTokenFailsIfNotSupported() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED_AS_COLLATERAL.selector, address(token3)));
        protocolF.removeCollateralToken(address(token3));
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
        token1.approve(address(diamond), depositAmount);

        // Expect events
        vm.expectEmit(true, true, false, false);
        emit PositionIdCreated(1, user1);

        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(1, address(token1), depositAmount);

        // Deposit collateral
        protocolF.depositCollateral(address(token1), depositAmount);

        vm.stopPrank();

        // Verify collateral was deposited
        uint256 collateralBalance = gettersF.getPositionCollateral(1, address(token1));
        assertEq(collateralBalance, depositAmount);

        // Verify token was transferred
        assertEq(token1.balanceOf(user1), 0);
        assertEq(token1.balanceOf(address(diamond)), depositAmount);

        // Verify position was created
        assertEq(positionManagerF.getPositionIdForUser(user1), 1);
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
        protocolF.depositCollateral{value: depositAmount}(address(1), depositAmount);
        vm.stopPrank();

        // Verify collateral was deposited
        uint256 collateralBalance = gettersF.getPositionCollateral(1, address(1));
        assertEq(collateralBalance, depositAmount);

        // Verify token was transferred
        assertEq(user1.balance, 0);
        assertEq(address(diamond).balance, depositAmount);

        // Verify position was created
        assertEq(positionManagerF.getPositionIdForUser(user1), 1);
    }

    function testDepositNativeTokenCollateralRevertWithDifferentMsgValueFromAmount() public {
        uint256 depositAmount = 1000 * 1e18;
        vm.deal(user1, depositAmount);

        vm.startPrank(user1);

        vm.expectRevert(abi.encodeWithSelector(AMOUNT_MISMATCH.selector, 1 ether, depositAmount));
        protocolF.depositCollateral{value: 1 ether}(address(1), depositAmount);
        vm.stopPrank();
    }

    function testDepositCollateralToExistingPosition() public {
        uint256 depositAmount1 = 1000 * 1e18;
        uint256 depositAmount2 = 500 * 1e18;

        // Create position first
        positionManagerF.createPositionFor(user1);
        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Mint tokens to user1
        token1.mint(user1, depositAmount1 + depositAmount2);

        vm.startPrank(user1);

        // First deposit
        token1.approve(address(diamond), depositAmount1);
        protocolF.depositCollateral(address(token1), depositAmount1);

        // Second deposit
        token1.approve(address(diamond), depositAmount2);

        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(positionId, address(token1), depositAmount2);

        protocolF.depositCollateral(address(token1), depositAmount2);

        vm.stopPrank();

        // Verify total collateral
        uint256 totalCollateral = gettersF.getPositionCollateral(positionId, address(token1));
        assertEq(totalCollateral, depositAmount1 + depositAmount2);
    }

    function testDepositCollateralFailsForAddressZero() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(0)));
        protocolF.depositCollateral(address(0), 1000);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        protocolF.depositCollateral(address(token1), 0);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForUnsupportedToken() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token3)));
        protocolF.depositCollateral(address(token3), 1000);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForInsufficientAllowance() public {
        uint256 depositAmount = 1000 * 1e18;
        token1.mint(user1, depositAmount);

        vm.startPrank(user1);
        // Don't approve or approve less than needed
        token1.approve(address(diamond), depositAmount - 1);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ALLOWANCE.selector));
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForInsufficientBalance() public {
        uint256 depositAmount = 1000 * 1e18;
        token1.mint(user1, depositAmount - 1); // Mint less than needed

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();
    }

    function testDepositCollateralFailsForBlacklistedUser() public {
        uint256 depositAmount = 1000 * 1e18;
        token1.mint(user1, depositAmount);

        // Blacklist user1
        positionManagerF.blacklistAddress(user1);

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);

        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, user1));
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();
    }

    function testSetCollateralTokenLTV() public {
        uint16 _newLTV = 5000; // 50%

        vm.expectEmit(true, true, true, false);
        emit CollateralTokenLTVUpdated(address(token1), baseTokenLTV, _newLTV);
        protocolF.setCollateralTokenLtv(address(token1), _newLTV);

        assertEq(_newLTV, gettersF.getCollateralTokenLTV(address(token1)));
    }

    function testSetCollateralTokenLTVFailsIfNotSecurityCouncil() public {
        uint16 _newLTV = 5000; // 50%

        vm.startPrank(user1);
        vm.expectRevert("ONLY_SECURITY_COUNCIL()");
        protocolF.setCollateralTokenLtv(address(token1), _newLTV);
    }

    function testSetCollateralTokenLTVFailsIfLTVBelow10Percent() public {
        uint16 _newLTV = 900; // 9%

        vm.expectRevert("LTV_BELOW_TEN_PERCENT()");
        protocolF.setCollateralTokenLtv(address(token1), _newLTV);
    }

    function testSetCollateralTokenLTVFailsForAddressZero() public {
        uint16 _newLTV = 1000; // 10%

        vm.expectRevert("ADDRESS_ZERO()");
        protocolF.setCollateralTokenLtv(address(0), _newLTV);
    }

    function testSetCollateralTokenLTVFailsIfTokenIsNotSupportedCollateral() public {
        uint16 _newLTV = 5000; // 50%
        address _unsupportedCollateral = address(0x123);

        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED_AS_COLLATERAL.selector, _unsupportedCollateral));
        protocolF.setCollateralTokenLtv(_unsupportedCollateral, _newLTV);
    }

    function testSetInterestRate() public {
        uint16 _newInterestRate = 5000; // 50%
        uint16 _newPenaltyRate = 1000; // 10%

        vm.expectEmit(true, true, true, false);
        emit InterestRateUpdated(_newInterestRate, _newPenaltyRate);
        protocolF.setInterestRate(_newInterestRate, _newPenaltyRate);

        (uint16 _interestBps, uint16 _penaltyBps) = gettersF.getInterestRate();
        assertEq(_newInterestRate, _interestBps);
        assertEq(_newPenaltyRate, _penaltyBps);
    }

    function testSetInterestRateFailsIfNotSecurityCouncil() public {
        uint16 _newInterestRate = 5000; // 50%
        uint16 _newPenaltyRate = 1000; // 10%

        vm.startPrank(user1);
        vm.expectRevert("ONLY_SECURITY_COUNCIL()");
        protocolF.setInterestRate(_newInterestRate, _newPenaltyRate);
    }

    function testSetInterestRateFailsIfRateIs0Percent() public {
        uint16 _newInterestRate = 0;
        uint16 _newPenaltyRate = 1000; // 10%

        vm.expectRevert("AMOUNT_ZERO()");
        protocolF.setInterestRate(_newInterestRate, _newPenaltyRate);
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
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Verify initial collateral balance
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), depositAmount);
        assertEq(token1.balanceOf(user1), 0);
        assertEq(token1.balanceOf(address(diamond)), depositAmount);

        // Withdraw some collateral
        vm.expectEmit(true, true, true, false);
        emit CollateralWithdrawn(positionId, address(token1), withdrawAmount);

        protocolF.withdrawCollateral(address(token1), withdrawAmount);
        vm.stopPrank();

        // Verify collateral was withdrawn
        uint256 remainingCollateral = depositAmount - withdrawAmount;
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), remainingCollateral);
        assertEq(token1.balanceOf(user1), withdrawAmount);
        assertEq(token1.balanceOf(address(diamond)), remainingCollateral);
    }

    function testWithdrawNativeTokenCollateral() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 300 * 1e18;

        // First deposit some collateral
        vm.deal(user1, depositAmount);
        vm.startPrank(user1);
        protocolF.depositCollateral{value: depositAmount}(address(1), depositAmount);

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Withdraw some collateral
        vm.expectEmit(true, true, true, false);
        emit CollateralWithdrawn(positionId, address(1), withdrawAmount);

        protocolF.withdrawCollateral(address(1), withdrawAmount);
        vm.stopPrank();

        // Verify collateral was withdrawn
        uint256 remainingCollateral = depositAmount - withdrawAmount;
        assertEq(gettersF.getPositionCollateral(positionId, address(1)), remainingCollateral);
        assertEq(user1.balance, withdrawAmount);
        assertEq(address(diamond).balance, remainingCollateral);
    }

    function testWithdrawAllCollateral() public {
        uint256 depositAmount = 1000 * 1e18;

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Withdraw all collateral
        vm.expectEmit(true, true, true, false);
        emit CollateralWithdrawn(positionId, address(token1), depositAmount);

        protocolF.withdrawCollateral(address(token1), depositAmount);
        vm.stopPrank();

        // Verify all collateral was withdrawn
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), 0);
        assertEq(token1.balanceOf(user1), depositAmount);
        assertEq(token1.balanceOf(address(diamond)), 0);
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
        token1.approve(address(diamond), depositAmount1);
        token2.approve(address(diamond), depositAmount2);

        protocolF.depositCollateral(address(token1), depositAmount1);
        protocolF.depositCollateral(address(token2), depositAmount2);

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Withdraw from both tokens
        protocolF.withdrawCollateral(address(token1), withdrawAmount1);
        protocolF.withdrawCollateral(address(token2), withdrawAmount2);
        vm.stopPrank();

        // Verify withdrawals
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), depositAmount1 - withdrawAmount1);
        assertEq(gettersF.getPositionCollateral(positionId, address(token2)), depositAmount2 - withdrawAmount2);
        assertEq(token1.balanceOf(user1), withdrawAmount1);
        assertEq(token2.balanceOf(user1), withdrawAmount2);
    }

    function testWithdrawCollateralFailsIfNoPosition() public {
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user1));
        protocolF.withdrawCollateral(address(token1), 1000);
        vm.stopPrank();
    }

    function testWithdrawCollateralFailsForInsufficientBalance() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 1500 * 1e18; // More than deposited

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);

        // Try to withdraw more than available
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        protocolF.withdrawCollateral(address(token1), withdrawAmount);
        vm.stopPrank();
    }

    function testWithdrawCollateralFailsForZeroAmount() public {
        uint256 depositAmount = 1000 * 1e18;

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);

        // Try to withdraw zero amount - this should fail at the LibProtocol level
        // Note: The current implementation doesn't have zero amount check in withdraw
        // but we can test withdrawing 0 should leave balances unchanged
        uint256 positionId = positionManagerF.getPositionIdForUser(user1);
        uint256 initialBalance = gettersF.getPositionCollateral(positionId, address(token1));
        uint256 initialUserBalance = token1.balanceOf(user1);

        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        protocolF.withdrawCollateral(address(token1), 0);

        // Balances should remain unchanged
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), initialBalance);
        assertEq(token1.balanceOf(user1), initialUserBalance);
        vm.stopPrank();
    }

    function testWithdrawCollateralFromEmptyBalance() public {
        uint256 depositAmount = 1000 * 1e18;

        // Deposit and then withdraw all
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        protocolF.withdrawCollateral(address(token1), depositAmount);

        // Try to withdraw again from empty balance
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        protocolF.withdrawCollateral(address(token1), 1);
        vm.stopPrank();
    }

    function testWithdrawCollateralDifferentTokensIndependently() public {
        uint256 depositAmount = 1000 * 1e18;

        // Deposit token1 only
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Should be able to withdraw token1
        protocolF.withdrawCollateral(address(token1), 500 * 1e18);

        // Should fail to withdraw token2 (no balance)
        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        protocolF.withdrawCollateral(address(token2), 1);

        // Verify token1 balance is correct and token2 balance is still 0
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), 500 * 1e18);
        assertEq(gettersF.getPositionCollateral(positionId, address(token2)), 0);
        vm.stopPrank();
    }

    function testWithdrawCollateralMultipleUsers() public {
        uint256 depositAmount = 1000 * 1e18;
        uint256 withdrawAmount = 300 * 1e18;

        // Both users deposit
        token1.mint(user1, depositAmount);
        token1.mint(user2, depositAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        vm.startPrank(user2);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 user1PositionId = positionManagerF.getPositionIdForUser(user1);
        uint256 user2PositionId = positionManagerF.getPositionIdForUser(user2);

        // User1 withdraws
        vm.startPrank(user1);
        protocolF.withdrawCollateral(address(token1), withdrawAmount);
        vm.stopPrank();

        // Verify only user1's collateral was affected
        assertEq(gettersF.getPositionCollateral(user1PositionId, address(token1)), depositAmount - withdrawAmount);
        assertEq(gettersF.getPositionCollateral(user2PositionId, address(token1)), depositAmount);
        assertEq(token1.balanceOf(user1), withdrawAmount);
        assertEq(token1.balanceOf(user2), 0);
        assertEq(token1.balanceOf(address(diamond)), depositAmount * 2 - withdrawAmount);
    }

    function testWithdrawCollateralPartialAmounts() public {
        uint256 depositAmount = 1000 * 1e18;

        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Multiple partial withdrawals
        protocolF.withdrawCollateral(address(token1), 100 * 1e18);
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), 900 * 1e18);
        assertEq(token1.balanceOf(user1), 100 * 1e18);

        protocolF.withdrawCollateral(address(token1), 200 * 1e18);
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), 700 * 1e18);
        assertEq(token1.balanceOf(user1), 300 * 1e18);

        protocolF.withdrawCollateral(address(token1), 700 * 1e18); // Withdraw remaining
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), 0);
        assertEq(token1.balanceOf(user1), 1000 * 1e18);

        vm.stopPrank();
    }

    function testWithdrawCollateralFailsIfItReducesCollateralBelowLimit() public {
        createVaultAndFund(1000000e18);
        uint256 depositAmount = 1000 * 1e18;

        // First deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);

        protocolF.borrow(address(token4), 2e6); // Borrow some amount to create debt

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Try to withdraw all collateral which should fail due to health factor
        vm.expectRevert(abi.encodeWithSelector(HEALTH_FACTOR_TOO_LOW.selector, uint256(0)));
        protocolF.withdrawCollateral(address(token1), depositAmount);
        vm.stopPrank();

        // Verify all collateral was withdrawn
        assertEq(gettersF.getPositionCollateral(positionId, address(token1)), depositAmount);
        assertEq(token1.balanceOf(user1), 0);
        assertEq(token1.balanceOf(address(diamond)), depositAmount);
    }

    // =============================================================
    //                      BORROW FUNCTION TESTS
    // =============================================================

    function testBorrow() public {
        createVaultAndFund(1000000e18);
        uint256 _collateralAmount = 10000 * 1e18; // $15M worth of token1 (10k * $1500)
        uint256 _borrowAmount = 1000 * 1e6; // $250k worth of token4 (1k * $250)

        // Deposit collateral first
        token1.mint(user1, _collateralAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), _collateralAmount);
        protocolF.depositCollateral(address(token1), _collateralAmount);

        uint256 _positionId = positionManagerF.getPositionIdForUser(user1);
        uint256 _healthFactor = gettersF.getHealthFactor(_positionId, 0);

        uint256 totalDebt = protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        assertEq(totalDebt, _borrowAmount);
        assertLt(gettersF.getHealthFactor(_positionId, 0), _healthFactor);
        assertEq(gettersF.getPositionBorrowedValue(_positionId), 250000e18);
        assertEq(token4.balanceOf(user1), _borrowAmount);
    }

    function testBorrowFailsWithoutPosition() public {
        uint256 borrowAmount = 1000 * 1e18;

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user1));
        protocolF.borrow(address(token1), borrowAmount);
        vm.stopPrank();
    }

    function testBorrowFailsForUnsupportedToken() public {
        // Create position first
        positionManagerF.createPositionFor(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token3)));
        protocolF.borrow(address(token3), 1000 * 1e18);
        vm.stopPrank();
    }

    function testRepaySuccess() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        protocolF.borrow(address(token4), borrowAmount);

        uint256 _vaultBalance = token4.balanceOf(vault);

        // Mint tokens to user1 for repayment
        token4.mint(user1, borrowAmount);
        token4.approve(address(diamond), borrowAmount);

        // Repay full amount
        uint256 remainingDebt = protocolF.repay(address(token4), borrowAmount);
        assertEq(remainingDebt, 0, "Debt should be zero after full repayment");
        assertEq(token4.balanceOf(vault), _vaultBalance + borrowAmount);
        vm.stopPrank();
    }

    function testRepayPartial() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        protocolF.borrow(address(token4), borrowAmount);

        // Mint tokens to user1 for partial repayment
        uint256 partialRepay = borrowAmount / 2;
        token4.mint(user1, partialRepay);
        token4.approve(address(diamond), partialRepay);

        uint256 remainingDebt = protocolF.repay(address(token4), partialRepay);

        assertGt(remainingDebt, 0, "Debt should remain after partial repayment");
        assertLt(remainingDebt, borrowAmount, "Debt should be less than initial borrow");
        vm.stopPrank();
    }

    function testRepayFailsForInsufficientAllowance() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        protocolF.borrow(address(token4), borrowAmount);

        // Mint tokens but do not approve
        token4.mint(user1, borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ALLOWANCE.selector));
        protocolF.repay(address(token4), borrowAmount);
        vm.stopPrank();
    }

    function testRepayFailsForInsufficientBalance() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        protocolF.borrow(address(token4), borrowAmount);
        token4.transfer(user2, borrowAmount); // reduce token balance for user1

        // Approve but do not mint enough tokens
        token4.approve(address(diamond), borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        protocolF.repay(address(token4), borrowAmount);
        vm.stopPrank();
    }

    function testRepayMoreThanDebt() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        protocolF.borrow(address(token4), borrowAmount);

        // Mint and approve more than debt
        token4.mint(user1, borrowAmount * 2);
        token4.approve(address(diamond), borrowAmount * 2);

        uint256 remainingDebt = protocolF.repay(address(token4), borrowAmount * 2);

        assertEq(remainingDebt, 0, "Debt should be zero after over-repayment");
        vm.stopPrank();
    }

    // =============================================================
    //                 REQUEST BORROW FUNCTION TESTS
    // =============================================================

    function testRequestBorrowWithValidSignature() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;
        uint256 tenure = 30 days;

        uint256 positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        uint256 signerPrivateKey = 0xA11CE;
        address signer = vm.addr(signerPrivateKey);
        positionManagerF.setRequestBorrowSigner(signer);

        BorrowRequest memory request = BorrowRequest({
            action: "BORROW_REQUEST",
            positionId: positionId,
            token: address(token4),
            amount: borrowAmount,
            tenureSeconds: tenure,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: 1,
            contractAddress: address(protocolF),
            wallet: user1
        });

        bytes32 digest = _borrowRequestDigest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        uint256 vaultBalanceBefore = token4.balanceOf(vault);
        (uint16 interestRate,) = gettersF.getInterestRate();

        vm.startPrank(user1);
        vm.expectEmit(true, true, true, false);
        emit LoanTaken(positionId, 1, address(token4), borrowAmount, tenure, interestRate);
        uint256 loanId = protocolF.requestBorrow(request, signature);
        vm.stopPrank();

        assertEq(loanId, 1, "First request should start at loanId 1");
        assertEq(token4.balanceOf(user1), borrowAmount, "Borrowed amount should transfer to borrower");
        assertEq(
            token4.balanceOf(vault), vaultBalanceBefore - borrowAmount, "Vault balance should reflect borrow amount"
        );
        uint256[] memory activeLoanIds = gettersF.getUserActiveLoanIds(positionId);
        assertEq(activeLoanIds.length, 1, "Position should track new active loan");
        assertEq(activeLoanIds[0], loanId, "Active loan ID should match the returned loanId");
        assertEq(
            gettersF.getOutstandingDebtForLoan(loanId),
            borrowAmount,
            "Outstanding debt should match the principal at creation"
        );
    }

    function testRequestBorrowFailsWitPositionIdMismatch() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;
        uint256 tenure = 30 days;

        uint256 positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        uint256 signerPrivateKey = 0xA11CE;
        address signer = vm.addr(signerPrivateKey);
        positionManagerF.setRequestBorrowSigner(signer);

        BorrowRequest memory request = BorrowRequest({
            action: "BORROW_REQUEST",
            positionId: positionId + 1,
            token: address(token4),
            amount: borrowAmount,
            tenureSeconds: tenure,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: 1,
            contractAddress: address(protocolF),
            wallet: user1
        });

        bytes32 digest = _borrowRequestDigest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(POSITION_ID_MISMATCH.selector, positionId, positionId + 1));
        protocolF.requestBorrow(request, signature);
        vm.stopPrank();
    }

    function testRequestBorrowFailsForOverUtilization() public {
        // Create a vault with 1000 tokens (token4 has 6 decimals)
        createVaultAndFund(1000 * 1e6);

        uint256 collateralAmount = 1000 * 1e18; // Sufficient collateral
        uint256 borrowAmount = 801 * 1e6; // Borrowing > 80% of totalDeposits (which is MAX_UTILIZATION)
        uint256 tenure = 30 days;

        uint256 positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        uint256 signerPrivateKey = 0xA11CE;
        address signer = vm.addr(signerPrivateKey);
        positionManagerF.setRequestBorrowSigner(signer);

        BorrowRequest memory request = BorrowRequest({
            action: "BORROW_REQUEST",
            positionId: positionId,
            token: address(token4),
            amount: borrowAmount,
            tenureSeconds: tenure,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: 1,
            contractAddress: address(protocolF),
            wallet: user1
        });

        bytes32 digest = _borrowRequestDigest(request);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_OVERUTILIZATION.selector));
        protocolF.requestBorrow(request, signature);
        vm.stopPrank();
    }

    // =============================================================
    //                  TAKE TENURED LOAN TESTS
    // =============================================================
    function testTakeLoan() public {
        createVaultAndFund(1000000e18);
        uint256 _collateralAmount = 10000 * 1e18; // $15M worth of token1 (10k * $1500)
        uint256 _borrowAmount = 1000 * 1e6; // $250k worth of token4 (1k * $250)
        uint256 _tenure = 365 days;

        // Deposit collateral first
        token1.mint(user1, _collateralAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), _collateralAmount);
        protocolF.depositCollateral(address(token1), _collateralAmount);
        uint256 _vaultBalenceBefore = token4.balanceOf(vault);

        uint256 _positionId = positionManagerF.getPositionIdForUser(user1);
        uint256 _healthFactor = gettersF.getHealthFactor(_positionId, 0);

        uint256 loanId = protocolF.takeLoan(address(token4), _borrowAmount, _tenure);
        uint256 totalDebt = gettersF.getTotalActiveDebt(_positionId);
        vm.stopPrank();

        assertEq(loanId, 1, "Loan ID should be 1 for the first loan");
        assertLt(gettersF.getHealthFactor(_positionId, 0), _healthFactor);
        assertEq(totalDebt, 250000e18);
        assertEq(token4.balanceOf(user1), _borrowAmount);
        assertEq(token4.balanceOf(vault), _vaultBalenceBefore - _borrowAmount);
    }

    function testTakeLoanFailsWithoutPosition() public {
        uint256 borrowAmount = 1000 * 1e18;

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user1));
        protocolF.takeLoan(address(token1), borrowAmount, 30 days);
        vm.stopPrank();
    }

    function testTakeLoanFailsForUnsupportedToken() public {
        // Create position first
        positionManagerF.createPositionFor(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token3)));
        protocolF.takeLoan(address(token3), 1000 * 1e18, 30 days);
        vm.stopPrank();
    }

    function testTakeLoanFailsForOverUtilization() public {
        // Vault is funded with 1000 tokens (token4 has 6 decimals)
        createVaultAndFund(1000 * 1e6);

        // Setup sufficient collateral: 1000 token1 ($1.5M)
        uint256 _collateralAmount = 1000 * 1e18;
        token1.mint(user1, _collateralAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), _collateralAmount);
        protocolF.depositCollateral(address(token1), _collateralAmount);

        // Attempt to borrow more than 80% (Constants.MAX_UTILIZATION) of total deposits
        uint256 _borrowAmount = 801 * 1e6;

        vm.expectRevert(abi.encodeWithSelector(TOKEN_OVERUTILIZATION.selector));
        protocolF.takeLoan(address(token4), _borrowAmount, 30 days);
        vm.stopPrank();
    }

    function testTakeLoanTenureTooShort() public {
        createVaultAndFund(1000 * 1e6);

        uint256 collateralAmount = 2000 ether;
        depositCollateralFor(address(this), address(token1), collateralAmount);
        uint256 principal = 1000 ether;
        uint256 shortTenure = 1 days - 1; // less than minimum

        vm.expectRevert(TENURE_TOO_SHORT.selector);
        protocolF.takeLoan(address(token4), principal, shortTenure);
    }

    function testRepayLoanForSuccess() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        uint256 _positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 365 days);

        uint256 _vaultBalance = token4.balanceOf(vault);

        vm.warp(block.timestamp + (365 days / 2)); // Warp half the tenure to accrue some interest

        uint256 _debtBeforeRepay = gettersF.getOutstandingDebtForLoan(_loanId);

        // Mint tokens to user1 for repayment
        token4.mint(user1, _debtBeforeRepay);
        token4.approve(address(diamond), _debtBeforeRepay);

        // Repay full amount
        uint256 remainingDebt = protocolF.repayLoanFor(_positionId, _loanId, _debtBeforeRepay);
        assertEq(remainingDebt, 0, "Debt should be zero after full repayment");
        assertEq(token4.balanceOf(vault), _vaultBalance + _debtBeforeRepay);
        vm.stopPrank();
    }

    function testRepayLoanForPartial() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        uint256 _positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 30 days);
        vm.warp(block.timestamp + 15 days); // Warp half the tenure to accrue some interest

        // Mint tokens to user1 for partial repayment
        uint256 partialRepay = borrowAmount;
        token4.mint(user1, partialRepay);
        token4.approve(address(diamond), partialRepay);

        uint256 remainingDebt = protocolF.repayLoanFor(_positionId, _loanId, partialRepay);

        assertGt(remainingDebt, 0, "Debt should remain after partial repayment");
        assertLt(remainingDebt, borrowAmount, "Debt should be less than initial borrow");
        vm.stopPrank();
    }

    function testRepayLoanForFailsForInsufficientAllowance() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        uint256 _positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 30 days);

        // Mint tokens but do not approve
        token4.mint(user1, borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ALLOWANCE.selector));
        protocolF.repayLoanFor(_positionId, _loanId, borrowAmount);
        vm.stopPrank();
    }

    function testRepayLoanForFailsForInsufficientBalance() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        uint256 _positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 365 days);
        token4.transfer(user2, borrowAmount); // reduce token balance for user1

        // Approve but do not mint enough tokens
        token4.approve(address(diamond), borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        protocolF.repayLoanFor(_positionId, _loanId, borrowAmount);
        vm.stopPrank();
    }

    function testRepayLoanForMoreThanDebt() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        uint256 _positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 365 days);

        // Mint and approve more than debt
        token4.mint(user1, borrowAmount * 2);
        token4.approve(address(diamond), borrowAmount * 2);
        uint256 balanceBeforeRepay = token4.balanceOf(user1);
        vm.warp(block.timestamp + 30 days); // Warp to accrue some interest

        uint256 debtBeforeRepay = gettersF.getOutstandingDebtForLoan(_loanId);
        uint256 remainingDebt = protocolF.repayLoanFor(_positionId, _loanId, borrowAmount * 2);

        assertEq(remainingDebt, 0, "Debt should be zero after over-repayment");
        assertEq(token4.balanceOf(user1), balanceBeforeRepay - debtBeforeRepay);
        vm.stopPrank();
    }

    function testRepayLoanSuccess() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 365 days);

        uint256 _vaultBalance = token4.balanceOf(vault);

        vm.warp(block.timestamp + (365 days / 2)); // Warp half the tenure to accrue some interest

        uint256 _debtBeforeRepay = gettersF.getOutstandingDebtForLoan(_loanId);

        // Mint tokens to user1 for repayment
        token4.mint(user1, _debtBeforeRepay);
        token4.approve(address(diamond), _debtBeforeRepay);

        // Repay full amount
        uint256 remainingDebt = protocolF.repayLoan(_loanId, _debtBeforeRepay);
        assertEq(remainingDebt, 0, "Debt should be zero after full repayment");
        assertEq(token4.balanceOf(vault), _vaultBalance + _debtBeforeRepay);
        vm.stopPrank();
    }

    function testRepayLoanPartial() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 30 days);
        vm.warp(block.timestamp + 15 days); // Warp half the tenure to accrue some interest

        // Mint tokens to user1 for partial repayment
        uint256 partialRepay = borrowAmount;
        token4.mint(user1, partialRepay);
        token4.approve(address(diamond), partialRepay);

        uint256 remainingDebt = protocolF.repayLoan(_loanId, partialRepay);

        assertGt(remainingDebt, 0, "Debt should remain after partial repayment");
        assertLt(remainingDebt, borrowAmount, "Debt should be less than initial borrow");
        vm.stopPrank();
    }

    function testRepayLoanFailsForInsufficientAllowance() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 30 days);

        // Mint tokens but do not approve
        token4.mint(user1, borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_ALLOWANCE.selector));
        protocolF.repayLoan(_loanId, borrowAmount);
        vm.stopPrank();
    }

    function testRepayLoanFailsForInsufficientBalance() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 365 days);
        token4.transfer(user2, borrowAmount); // reduce token balance for user1

        // Approve but do not mint enough tokens
        token4.approve(address(diamond), borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(INSUFFICIENT_BALANCE.selector));
        protocolF.repayLoan(_loanId, borrowAmount);
        vm.stopPrank();
    }

    function testRepayLoanMoreThanDebt() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 365 days);

        // Mint and approve more than debt
        token4.mint(user1, borrowAmount * 2);
        token4.approve(address(diamond), borrowAmount * 2);
        uint256 balanceBeforeRepay = token4.balanceOf(user1);
        vm.warp(block.timestamp + 30 days); // Warp to accrue some interest

        uint256 debtBeforeRepay = gettersF.getOutstandingDebtForLoan(_loanId);
        uint256 remainingDebt = protocolF.repayLoan(_loanId, borrowAmount * 2);

        assertEq(remainingDebt, 0, "Debt should be zero after over-repayment");
        assertEq(token4.balanceOf(user1), balanceBeforeRepay - debtBeforeRepay);
        vm.stopPrank();
    }

    function testRepayLoanFailsIfSenderIsNotOwnerOfLoan() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);
        uint256 _positionId = depositCollateralFor(user2, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), borrowAmount, 365 days);
        vm.stopPrank();

        // Attempt to repay from a different user
        vm.startPrank(user2);
        token4.mint(user2, borrowAmount);
        token4.approve(address(diamond), borrowAmount);

        vm.expectRevert(abi.encodeWithSelector(NOT_LOAN_OWNER.selector, _positionId));
        protocolF.repayLoan(_loanId, borrowAmount);
        vm.stopPrank();
    }

    function _borrowRequestDigest(BorrowRequest memory _request) internal pure returns (bytes32) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _request.action,
                _request.positionId,
                _request.token,
                _request.amount,
                _request.tenureSeconds,
                _request.sourceChainId,
                _request.targetChainId,
                _request.nonce,
                _request.contractAddress,
                _request.wallet
            )
        );
        return MessageHashUtils.toEthSignedMessageHash(messageHash);
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
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Calculate health factor
        uint256 healthFactor = gettersF.getHealthFactor(positionId, currentBorrowValue);

        // Expected: (1.5M * 0.8) / 0.5M = 2.4
        uint256 collateralValue = 1000 * 1500 * 1e18;
        uint256 adjustedCollateralValue = (collateralValue * 8000) / 10000;
        uint256 expectedHealthFactor = (adjustedCollateralValue * 1e18) / currentBorrowValue;

        assertEq(healthFactor, expectedHealthFactor, "Health factor calculation should be correct");
    }

    function testGetHealthFactorEdgeCases() public {
        // Test with zero collateral and zero borrow
        positionManagerF.createPositionFor(user1);
        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // With zero collateral and zero additional borrow, should return 0
        uint256 healthFactor = gettersF.getHealthFactor(positionId, 0);
        assertEq(healthFactor, 0, "Zero collateral with zero borrow should return 0");

        // With zero collateral and some borrow, should return 0
        uint256 healthFactorWithBorrow = gettersF.getHealthFactor(positionId, 1000 * 1e18);
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
        token1.approve(address(diamond), depositAmount1);
        token2.approve(address(diamond), depositAmount2);

        protocolF.depositCollateral(address(token1), depositAmount1);
        protocolF.depositCollateral(address(token2), depositAmount2);
        vm.stopPrank();

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Test individual token values
        (, uint256 token1Value) = priceOracleF.getTokenValueInUSD(address(token1), depositAmount1);
        (, uint256 token2Value) = priceOracleF.getTokenValueInUSD(address(token2), depositAmount2);

        assertEq(token1Value, 500 * 1500 * 1e18, "Token1 value should be correct");
        assertEq(token2Value, 1000 * 300 * 1e18, "Token2 value should be correct");

        // Test total collateral value
        uint256 totalCollateralValue = gettersF.getPositionCollateralValue(positionId);
        assertEq(totalCollateralValue, token1Value + token2Value, "Total collateral should sum individual values");

        // Test borrowed value (should be 0)
        uint256 borrowedValue = gettersF.getPositionBorrowedValue(positionId);
        assertEq(borrowedValue, 0, "Borrowed value should be 0");

        // Test health factor with hypothetical borrow
        uint256 hypotheticalBorrow = 200000 * 1e18; // $200k
        uint256 healthFactor = gettersF.getHealthFactor(positionId, hypotheticalBorrow);

        // Expected: ((750k + 300k) * 0.8) / 200k = 4.2
        uint256 expectedHealthFactor = (totalCollateralValue * 8000 * 1e18 / 10000) / hypotheticalBorrow;
        assertEq(healthFactor, expectedHealthFactor, "Health factor should be calculated correctly");
    }

    // =============================================================
    //                       VALUE CALCULATION TESTS
    // =============================================================
    function testGetPositionCollateralValueEmptyPosition() public {
        // Create empty position
        positionManagerF.createPositionFor(user1);
        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Should return 0 for empty position
        uint256 value = gettersF.getPositionCollateralValue(positionId);
        assertEq(value, 0);
    }

    function testGetPositionBorrowedValue() public {
        // Create a position
        positionManagerF.createPositionFor(user1);
        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Should return 0 for new position with no borrows
        uint256 value = gettersF.getPositionBorrowedValue(positionId);
        assertEq(value, 0);
    }

    function testGetHealthFactorWithNoBorrows() public {
        // Create a position with collateral
        uint256 depositAmount = 1000 * 1e18;
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Health factor should be max (type(uint256).max) when no borrows
        uint256 healthFactor = gettersF.getHealthFactor(positionId, 0);
        assertEq(healthFactor, 12e41);
    }

    function testGetHealthFactorWithCurrentBorrowValue() public {
        uint256 currentBorrowValue = 500 * 1e18; // $500 worth of borrow
        uint256 positionId = depositCollateralFor(user1, address(token1), (1 * 1e18));

        // With collateral value 0 and borrow value > 0, health factor calculation
        // will depend on the actual collateral value from price feeds
        // This will likely revert or return 0 without proper price feeds
        uint256 _healthFactor = gettersF.getHealthFactor(positionId, currentBorrowValue);
        assertEq(_healthFactor, 2.4e18);

        // 100% collateral value
        _healthFactor = gettersF.getHealthFactor(positionId, 1500e18);
        assertEq(_healthFactor, 0.8e18);

        // 80% liquidation threshold
        _healthFactor = gettersF.getHealthFactor(positionId, 1200e18);
        assertEq(_healthFactor, 1e18);
    }

    // =============================================================
    //                       VIEW FUNCTION TESTS
    // =============================================================

    function testIsCollateralTokenSupported() public view {
        assertTrue(gettersF.isCollateralTokenSupported(address(token1)));
        assertTrue(gettersF.isCollateralTokenSupported(address(token2)));
        assertFalse(gettersF.isCollateralTokenSupported(address(token3)));
        assertFalse(gettersF.isCollateralTokenSupported(address(0x999)));
    }

    function testGetAllCollateralTokens() public view {
        address[] memory tokens = gettersF.getAllCollateralTokens();

        assertEq(tokens.length, 3);
        assertTrue(tokens[0] == address(token1) || tokens[1] == address(token1));
        assertTrue(tokens[0] == address(token2) || tokens[1] == address(token2));
    }

    function testGetAllCollateralTokensAfterAddingAndRemoving() public {
        // Add a new token
        protocolF.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);

        address[] memory tokens = gettersF.getAllCollateralTokens();
        assertEq(tokens.length, 4);

        // Remove a token
        protocolF.removeCollateralToken(address(token1));

        tokens = gettersF.getAllCollateralTokens();
        assertEq(tokens.length, 3);

        // Verify token1 is not in the array
        for (uint256 i = 0; i < tokens.length; i++) {
            assertTrue(tokens[i] != address(token1));
        }
    }

    function testGetPositionCollateral() public {
        uint256 depositAmount = 1000 * 1e18;

        // Initially should be 0
        assertEq(gettersF.getPositionCollateral(1, address(token1)), 0);

        // Deposit some collateral
        token1.mint(user1, depositAmount);
        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount);
        protocolF.depositCollateral(address(token1), depositAmount);
        vm.stopPrank();

        // Should now return the deposited amount
        assertEq(gettersF.getPositionCollateral(1, address(token1)), depositAmount);

        // Other tokens should still be 0
        assertEq(gettersF.getPositionCollateral(1, address(token2)), 0);
        assertEq(gettersF.getPositionCollateral(2, address(token1)), 0);
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
        token1.approve(address(diamond), user1Amount);
        token2.approve(address(diamond), user1Amount);
        protocolF.depositCollateral(address(token1), user1Amount);
        protocolF.depositCollateral(address(token2), user1Amount / 2);
        vm.stopPrank();

        // User2 deposits
        vm.startPrank(user2);
        token1.approve(address(diamond), user2Amount);
        protocolF.depositCollateral(address(token1), user2Amount);
        vm.stopPrank();

        uint256 user1PositionId = positionManagerF.getPositionIdForUser(user1);
        uint256 user2PositionId = positionManagerF.getPositionIdForUser(user2);

        // Verify individual collateral amounts
        assertEq(gettersF.getPositionCollateral(user1PositionId, address(token1)), user1Amount);
        assertEq(gettersF.getPositionCollateral(user1PositionId, address(token2)), user1Amount / 2);
        assertEq(gettersF.getPositionCollateral(user2PositionId, address(token1)), user2Amount);
        assertEq(gettersF.getPositionCollateral(user2PositionId, address(token2)), 0);
    }

    function testGetPositionCollateralValue() public {
        protocolF.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        uint256 depositAmount1 = 2 * 1e18; // 2 tokens of token1 (18 decimals)
        uint256 depositAmount2 = 10 * 1e18; // 10 tokens of token2 (18 decimals)
        uint256 depositAmount3 = 1000 * 1e6; // 1000 tokens of token3 (6 decimals)

        // Deposit collateral
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);
        token3.mint(user1, depositAmount3);

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount1);
        token2.approve(address(diamond), depositAmount2);
        token3.approve(address(diamond), depositAmount3);

        protocolF.depositCollateral(address(token1), depositAmount1);
        protocolF.depositCollateral(address(token2), depositAmount2);
        protocolF.depositCollateral(address(token3), depositAmount3);
        vm.stopPrank();

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Calculate expected value
        // token1: 2 * $1500 = $3000
        // token2: 10 * $300 = $3000
        // token3: 1000 * $1 = $1000
        // Total = $7000
        uint256 expectedValue = 7000 * 1e18; // the value is returned with 18 decimals

        uint256 collateralValue = gettersF.getPositionCollateralValue(positionId);
        assertEq(collateralValue, expectedValue);
    }

    function testGetPositionBorrowableCollateralValue() public {
        protocolF.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        uint256 depositAmount1 = 2 * 1e18; // 2 tokens of token1 (18 decimals)
        uint256 depositAmount2 = 10 * 1e18; // 10 tokens of token2 (18 decimals)
        uint256 depositAmount3 = 1000 * 1e6; // 1000 tokens of token3 (6 decimals)

        // Deposit collateral
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);
        token3.mint(user1, depositAmount3);

        protocolF.setCollateralTokenLtv(address(token2), 5000); // set to 50%
        protocolF.setCollateralTokenLtv(address(token3), 5000); // set to 50%

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount1);
        token2.approve(address(diamond), depositAmount2);
        token3.approve(address(diamond), depositAmount3);

        protocolF.depositCollateral(address(token1), depositAmount1);
        protocolF.depositCollateral(address(token2), depositAmount2);
        protocolF.depositCollateral(address(token3), depositAmount3);
        vm.stopPrank();

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);

        // Calculate expected value
        // token1: 2 * $1500 * 0.8 = $2400
        // token2: 10 * $300 * 0.5 = $1500
        // token3: 1000 * $1 * 0.5 = $500
        // Total = $4400
        uint256 expectedValue = 4400 * 1e18; // the value is returned with 18 decimals

        uint256 collateralValue = gettersF.getPositionBorrowableCollateralValue(positionId);
        assertEq(collateralValue, expectedValue);
    }

    function testGetPositionBorrowableCollateralValueReducesWithActiveLoans() public {
        createVaultAndFund(1000000e18);
        protocolF.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        uint256 depositAmount1 = 2 * 1e18; // 2 tokens of token1 (18 decimals)
        uint256 depositAmount2 = 10 * 1e18; // 10 tokens of token2 (18 decimals)
        uint256 depositAmount3 = 1000 * 1e6; // 1000 tokens of token3 (6 decimals)
        uint256 borrowAmount = 10 * 1e6;

        // Deposit collateral
        token1.mint(user1, depositAmount1);
        token2.mint(user1, depositAmount2);
        token3.mint(user1, depositAmount3);

        protocolF.setCollateralTokenLtv(address(token2), 5000); // set to 50%
        protocolF.setCollateralTokenLtv(address(token3), 5000); // set to 50%

        vm.startPrank(user1);
        token1.approve(address(diamond), depositAmount1);
        token2.approve(address(diamond), depositAmount2);
        token3.approve(address(diamond), depositAmount3);

        protocolF.depositCollateral(address(token1), depositAmount1);
        protocolF.depositCollateral(address(token2), depositAmount2);
        protocolF.depositCollateral(address(token3), depositAmount3);

        protocolF.takeLoan(address(token4), borrowAmount, 365 days);
        vm.stopPrank();

        uint256 positionId = positionManagerF.getPositionIdForUser(user1);
        (, uint256 borrowValue) = priceOracleF.getTokenValueInUSD(address(token4), borrowAmount);

        // Calculate expected value
        // token1: 2 * $1500 * 0.8 = $2400
        // token2: 10 * $300 * 0.5 = $1500
        // token3: 1000 * $1 * 0.5 = $500
        // Total = $4400
        uint256 expectedValue = 4400 * 1e18;

        assertEq((expectedValue - borrowValue), gettersF.getPositionBorrowableCollateralValue(positionId));
        assertEq(expectedValue, gettersF.getPositionUtilizableCollateralValue(positionId));
    }

    function testGetUserActiveLoanIds() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount1 = 1000 * 1e6;
        uint256 borrowAmount2 = 2000 * 1e6;

        uint256 _positionId = depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 loanId1 = protocolF.takeLoan(address(token4), borrowAmount1, 365 days);
        uint256 loanId2 = protocolF.takeLoan(address(token4), borrowAmount2, 365 days);
        vm.stopPrank();

        uint256[] memory activeLoanIds = gettersF.getUserActiveLoanIds(_positionId);

        assertEq(activeLoanIds.length, 2, "User should have 2 active loans");
        assertEq(activeLoanIds[0], loanId1, "First loan ID should match");
        assertEq(activeLoanIds[1], loanId2, "Second loan ID should match");
    }

    function testGetActiveLoanIds() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount1 = 1000 * 1e6;
        uint256 borrowAmount2 = 2000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);
        depositCollateralFor(user2, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 loanId1 = protocolF.takeLoan(address(token4), borrowAmount1, 365 days);
        uint256 loanId2 = protocolF.takeLoan(address(token4), borrowAmount2, 365 days);
        token4.approve(address(diamond), borrowAmount1);
        protocolF.repayLoan(loanId1, borrowAmount1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 loanId3 = protocolF.takeLoan(address(token4), borrowAmount1, 365 days);
        uint256 loanId4 = protocolF.takeLoan(address(token4), borrowAmount2, 365 days);
        uint256 loanId5 = protocolF.takeLoan(address(token4), borrowAmount1, 365 days);

        token4.approve(address(diamond), borrowAmount2);
        protocolF.repayLoan(loanId4, borrowAmount2);
        vm.stopPrank();

        uint256[] memory activeLoanIds = gettersF.getActiveLoanIds();

        assertEq(activeLoanIds.length, 3, "should have 3 active loans");
        assertEq(activeLoanIds[0], loanId2, "First loan ID should match");
        assertEq(activeLoanIds[1], loanId3, "Second loan ID should match");
        assertEq(activeLoanIds[2], loanId5, "Third loan ID should match");
    }

    function testGetLoanDetails() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;
        uint256 tenure = 365 days;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        uint256 loanId = protocolF.takeLoan(address(token4), borrowAmount, tenure);
        token4.approve(address(diamond), borrowAmount / 2);
        protocolF.repayLoan(loanId, borrowAmount / 2);
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
        ) = gettersF.getLoanDetails(loanId);

        assertEq(positionId, 2, "Position ID should match");
        assertEq(token, address(token4), "Loan token address should match");
        assertEq(principal, borrowAmount / 2, "Principal amount should match"); // if loan is not fully repaid principal would be the amount loan is calculated by
        assertEq(
            debt,
            (borrowAmount * 20 / 200) + (borrowAmount / 2),
            "debt amount should have increased by 20% of principal minus repaid"
        );
        assertEq(repaid, borrowAmount / 2, "Repaid amount should match");
        assertEq(startTimestamp, (block.timestamp - 365 days), "Start time should match");
        assertEq(tenureSeconds, tenure, "End time should match");
        assertEq(annualRateBps, 2000, "Interest rate should match");
        assertEq(penaltyRateBps, 500, "Penalty rate should match");
        assertEq(status, uint8(LoanStatus.FULFILLED), "Loan should not be marked as repaid");
    }

    function testWithdrawCollateralAboveLTVWithActiveBorrowFails() public {
        createVaultAndFund(1000000e18);
        uint256 collateralAmount = 10000 * 1e18;
        uint256 borrowAmount = 1000 * 1e6;

        depositCollateralFor(user1, address(token1), collateralAmount);

        vm.startPrank(user1);
        protocolF.takeLoan(address(token4), borrowAmount, 90 days);

        // Attempt to withdraw collateral that would breach LTV
        vm.expectRevert(abi.encodeWithSelector(HEALTH_FACTOR_TOO_LOW.selector, 0));
        protocolF.withdrawCollateral(address(token1), collateralAmount);
        vm.stopPrank();
    }

    function testBorrowDoubleCountingBugFix() public {
        // H-02
        // Testing that the total borrows in the vault is equal to the amount borrowed by the user
        createVaultAndFund(1000000e18);
        uint256 _collateralAmount = 10000 * 1e18; // $15M worth of token1 (10k * $1500)
        uint256 _borrowAmount = 1000 * 1e6; // $250k worth of token4 (1k * $250)

        // Deposit collateral first
        token1.mint(user1, _collateralAmount);

        vm.startPrank(user1);
        token1.approve(address(diamond), _collateralAmount);
        protocolF.depositCollateral(address(token1), _collateralAmount);

        protocolF.borrow(address(token4), _borrowAmount);
        vm.stopPrank();

        VaultConfiguration memory config = vaultManagerF.getTokenVaultConfig(address(token4));
        uint256 totalBorrowInVault = TokenVault(vault).totalBorrow();

        assertEq(totalBorrowInVault, _borrowAmount);
        assertEq(config.totalBorrows, _borrowAmount);
    }
}
