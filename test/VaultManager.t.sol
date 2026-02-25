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

        address diamond = address(vaultManagerF);

        token1.mint(diamond, _amount);
        vm.startPrank(diamond);
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
}
