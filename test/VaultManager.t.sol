// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/VaultManagerFacet.sol";
import "../contracts/Diamond.sol";
import {Base} from "./Base.t.sol";

import "../contracts/models/Protocol.sol";
import "../contracts/models/Error.sol";
import "../contracts/models/Event.sol";

import {TokenVault} from "../contracts/TokenVault.sol";

contract PositionManagerTest is Base {
    address linkHolder = 0x4281eCF07378Ee595C564a59048801330f3084eE; //sepolia

    TokenVault tokenVault1;
    TokenVault tokenVault2;

    function setUp() public override {
        super.setUp();
        _deployErc20Tokens();
        _deployVaults();
    }

    function testDeposit() public {
        address _token = address(token1);
        uint256 _amount = 1000 ether;

        token1.mint(address(this), _amount);
        token1.approve(address(diamond), _amount);

        TokenVault tokenVault = TokenVault(payable(vaultManagerF.getTokenVault(_token)));

        vm.expectEmit(true, true, true, true);
        emit Deposit(1, _token, _amount);
        vaultManagerF.deposit(_token, _amount);

        assertEq(token1.balanceOf(user1), 0);
        assertEq(token1.balanceOf(address(tokenVault)), _amount);
        assertEq(ERC20Mock(vaultManagerF.getTokenVault(_token)).balanceOf(address(this)), _amount);
    }

    function testVaultDeposit() public {
        address _token = address(token1);
        uint256 _amount = 1000 ether;

        token1.mint(user1, _amount);
        vm.startPrank(user1);
        token1.approve(address(tokenVault1), _amount);

        tokenVault1.deposit(_amount, user1);

        assertEq(token1.balanceOf(user1), 0);
        assertEq(token1.balanceOf(address(tokenVault1)), _amount);
        assertEq(ERC20Mock(vaultManagerF.getTokenVault(_token)).balanceOf(user1), _amount);

        vm.stopPrank();
    }

    function testWithdraw() public {
        address _token = address(token1);
        uint256 _amount = 1000 ether;
        uint256 _halfAmount = _amount / 2;

        token1.mint(address(this), _amount);
        token1.approve(address(diamond), _amount);
        vaultManagerF.deposit(_token, _amount);

        tokenVault1.approve(address(diamond), _halfAmount);

        vm.expectEmit(true, true, true, true);
        emit Withdrawal(1, _token, _halfAmount);
        vaultManagerF.withdraw(_token, _halfAmount);

        assertEq(token1.balanceOf(address(this)), _halfAmount);
        assertEq(token1.balanceOf(address(tokenVault1)), _halfAmount);
        assertEq(tokenVault1.balanceOf(address(this)), _halfAmount);
    }

    function testDeployVault() public {
        address _token = address(0x123);
        address _tokenVault = vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);
        assertTrue(vaultManagerF.tokenIsSupported(_token));
        assertEq(_tokenVault, vaultManagerF.getTokenVault(_token));
    }

    function testDeploVaultEmitTokenAdded() public {
        address _token = address(0x123);
        vm.expectEmit(true, false, true, true);
        emit TokenAdded(_token, address(0));
        vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);
    }

    function testOnlyContractOwnerCanDeployVault() public {
        address _token = address(0x123);
        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);
    }

    function testPauseTokenSupport() public {
        address _token = address(0x123);
        vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);

        vaultManagerF.pauseTokenSupport(_token);
        assertFalse(vaultManagerF.tokenIsSupported(_token));
    }

    function testOnlyContractOwnerCanPauseTokenSupport() public {
        address _token = address(0x123);
        vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);

        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.pauseTokenSupport(_token);
    }

    function testResumeTokenSupport() public {
        address _token = address(0x123);
        vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);
        vaultManagerF.pauseTokenSupport(_token);

        vaultManagerF.resumeTokenSupport(_token);
        assertTrue(vaultManagerF.tokenIsSupported(_token));
    }

    function testOnlyContractOwnerCanResumeTokenSupport() public {
        address _token = address(0x123);
        vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);
        vaultManagerF.pauseTokenSupport(_token);

        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.resumeTokenSupport(_token);
    }

    function testCannotPauseOrResumeTokenSupportForTokenThatIsNotSupported() public {
        address _token = address(0x123);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, _token));
        vaultManagerF.pauseTokenSupport(_token);

        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, _token));
        vaultManagerF.resumeTokenSupport(_token);
    }

    function testCannotAddAddressZeroAsSupportedToken() public {
        address _token = address(0);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);
    }

    function testCannotPauseAddressZeroAsSupportedToken() public {
        address _token = address(0);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        vaultManagerF.pauseTokenSupport(_token);
    }

    function testCannotResumeAddressZeroAsSupportedToken() public {
        address _token = address(0);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        vaultManagerF.resumeTokenSupport(_token);
    }

    function testCannotDeployVaultMultipleTimesForSameToken() public {
        address _token = address(0x123);
        address _vaultToken = vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);

        vm.expectRevert(abi.encodeWithSelector(TOKEN_ALREADY_SUPPORTED.selector, _token, _vaultToken));
        vaultManagerF.deployVault(_token, address(0xdead), "Diff name", "Diff", defaultConfig);
    }

    function testCannotDeployVaultForTokensWithPausedSupport() public {
        address _token = address(0x123);
        address _vaultToken = vaultManagerF.deployVault(_token, address(0xdead), "Test token", "TesT", defaultConfig);
        vaultManagerF.pauseTokenSupport(_token);

        vm.expectRevert(abi.encodeWithSelector(TOKEN_ALREADY_SUPPORTED.selector, _token, _vaultToken));
        vaultManagerF.deployVault(_token, address(0xdead), "Diff name", "Diff", defaultConfig);
    }

    function _deployVaults() internal {
        tokenVault1 = TokenVault(
            payable(vaultManagerF.deployVault(address(token1), address(0xdead), "Hodl Dai", "HDAI", defaultConfig))
        );
        tokenVault2 = TokenVault(
            payable(vaultManagerF.deployVault(address(token2), address(0xdead), "Hodl Xai", "HXAI", defaultConfig))
        );
    }

    function _deployErc20Tokens() internal {
        token1 = new ERC20Mock(18);
        token2 = new ERC20Mock(18);
    }

    // ====== Vault Config Setter Tests ======
    function testSetReserveFactor() public {
        address _token = address(token1);
        uint16 newReserveFactor = 3000;
        VaultConfiguration memory beforeConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertTrue(beforeConfig.reserveFactor != newReserveFactor);
        vaultManagerF.setReserveFactor(_token, newReserveFactor);
        VaultConfiguration memory afterConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertEq(afterConfig.reserveFactor, newReserveFactor);
    }

    function testSetReserveFactorRevertsOnZero() public {
        address _token = address(token1);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        vaultManagerF.setReserveFactor(_token, 0);
    }

    function testSetReserveFactorRevertsIfNotCouncil() public {
        address _token = address(token1);
        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.setReserveFactor(_token, 3000);
        vm.stopPrank();
    }

    function testSetBaseRate() public {
        address _token = address(token1);
        uint16 newBaseRate = 400;
        VaultConfiguration memory beforeConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertTrue(beforeConfig.baseRate != newBaseRate);
        vaultManagerF.setBaseRate(_token, newBaseRate);
        VaultConfiguration memory afterConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertEq(afterConfig.baseRate, newBaseRate);
    }

    function testSetBaseRateRevertsOnZero() public {
        address _token = address(token1);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        vaultManagerF.setBaseRate(_token, 0);
    }

    function testSetBaseRateRevertsIfSlopeLower() public {
        address _token = address(token1);
        // set slopeRate to 500 first
        vaultManagerF.setSlopeRate(_token, 500);
        vm.expectRevert(abi.encodeWithSelector(BAD_RATE.selector));
        vaultManagerF.setBaseRate(_token, 600);
    }

    function testSetBaseRateRevertsIfNotCouncil() public {
        address _token = address(token1);
        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.setBaseRate(_token, 400);
        vm.stopPrank();
    }

    function testSetSlopeRate() public {
        address _token = address(token1);
        uint16 newSlopeRate = 2000;
        VaultConfiguration memory beforeConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertTrue(beforeConfig.slopeRate != newSlopeRate);
        vaultManagerF.setSlopeRate(_token, newSlopeRate);
        VaultConfiguration memory afterConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertEq(afterConfig.slopeRate, newSlopeRate);
    }

    function testSetSlopeRateRevertsOnZero() public {
        address _token = address(token1);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        vaultManagerF.setSlopeRate(_token, 0);
    }

    function testSetSlopeRateRevertsIfBaseHigher() public {
        address _token = address(token1);
        vm.expectRevert(abi.encodeWithSelector(BAD_RATE.selector));
        vaultManagerF.setSlopeRate(_token, 300);
    }

    function testSetSlopeRateRevertsIfNotCouncil() public {
        address _token = address(token1);
        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.setSlopeRate(_token, 2000);
        vm.stopPrank();
    }

    function testSetOptimalUtilization() public {
        address _token = address(token1);
        uint16 newOptimalUtilization = 8000;
        VaultConfiguration memory beforeConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertTrue(beforeConfig.optimalUtilization != newOptimalUtilization);
        vaultManagerF.setOptimalUtilization(_token, newOptimalUtilization);
        VaultConfiguration memory afterConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertEq(afterConfig.optimalUtilization, newOptimalUtilization);
    }

    function testSetOptimalUtilizationRevertsOnZero() public {
        address _token = address(token1);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        vaultManagerF.setOptimalUtilization(_token, 0);
    }

    function testSetOptimalUtilizationRevertsIfTooLow() public {
        address _token = address(token1);
        vm.expectRevert(abi.encodeWithSelector(BAD_RATE.selector));
        vaultManagerF.setOptimalUtilization(_token, 4000);
    }

    function testSetOptimalUtilizationRevertsIfNotCouncil() public {
        address _token = address(token1);
        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.setOptimalUtilization(_token, 8000);
        vm.stopPrank();
    }

    function testSetLiquidationBonus() public {
        address _token = address(token1);
        uint16 newLiquidationBonus = 900;
        VaultConfiguration memory beforeConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertTrue(beforeConfig.liquidationBonus != newLiquidationBonus);
        vaultManagerF.setLiquidationBonus(_token, newLiquidationBonus);
        VaultConfiguration memory afterConfig = vaultManagerF.getTokenVaultConfig(_token);
        assertEq(afterConfig.liquidationBonus, newLiquidationBonus);
    }

    function testGetTokenVaultDetails() public {
        address _token = address(token1);
        (uint256 deposits, uint256 borrows) = vaultManagerF.getTokenVaultDetails(_token);
        VaultConfiguration memory config = vaultManagerF.getTokenVaultConfig(_token);
        assertEq(deposits, config.totalDeposits);
        assertEq(borrows, config.totalBorrows);

        // After deposit
        uint256 depositAmount = 1000 ether;
        token1.mint(address(this), depositAmount);
        token1.approve(address(diamond), depositAmount);
        vaultManagerF.deposit(_token, depositAmount);
        (deposits, borrows) = vaultManagerF.getTokenVaultDetails(_token);
        assertEq(deposits, depositAmount);
        assertEq(borrows, 0);
    }

    function testSetLiquidationBonusRevertsIfTooHigh() public {
        address _token = address(token1);
        vm.expectRevert(abi.encodeWithSelector(BAD_RATE.selector));
        vaultManagerF.setLiquidationBonus(_token, 2000);
    }

    function testSetLiquidationBonusRevertsIfNotCouncil() public {
        address _token = address(token1);
        vm.startPrank(linkHolder);
        vm.expectRevert(abi.encodeWithSelector(ONLY_SECURITY_COUNCIL.selector));
        vaultManagerF.setLiquidationBonus(_token, 900);
        vm.stopPrank();
    }
}
