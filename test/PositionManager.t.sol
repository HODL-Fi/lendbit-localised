// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/PositionManagerFacet.sol";
import "../contracts/Diamond.sol";

import "../contracts/models/Error.sol";
import "../contracts/models/Event.sol";

contract PositionManagerTest is Base {
    function setUp() public override {
        super.setUp();
        positionManagerF.whitelistAddress(address(0xa));
        positionManagerF.whitelistAddress(address(0xb));
        positionManagerF.whitelistAddress(address(0xdead));
        positionManagerF.whitelistAddress(address(0xacc));
    }

    function testCreatePositionFor() public {
        positionManagerF.whitelistAddress(address(0xa));
        positionManagerF.whitelistAddress(address(0xb));
        uint256 _positionIdA = positionManagerF.createPositionFor(address(0xa));
        uint256 _positionIdB = positionManagerF.createPositionFor(address(0xb));
        assertEq(_positionIdA, 1);
        assertEq(_positionIdB, 2);
    }

    function testCreatePositionForFailsWithDulplicateAddress() public {
        address _user = address(0xa);
        positionManagerF.createPositionFor(_user);

        vm.expectRevert(abi.encodeWithSelector(ADDRESS_EXISTS.selector, _user));
        positionManagerF.createPositionFor(_user);
    }

    function testCreatePositionForEmitPositionCreatedEvent() public {
        address _user = address(0xa);
        vm.expectEmit(true, true, true, true);
        emit PositionIdCreated(1, _user);
        positionManagerF.createPositionFor(_user);
    }

    function testTransferPositionOwnership() public {
        address _user = address(0xdead);
        address _newAddress = address(0xacc);

        uint256 _positionId = positionManagerF.createPositionFor(_user);

        vm.startPrank(_user);
        uint256 _retainedPositionId = positionManagerF.transferPositionOwnership(_newAddress);

        assertEq(_retainedPositionId, _positionId);
        assertEq(positionManagerF.getPositionIdForUser(_newAddress), _positionId);
        assertEq(positionManagerF.getPositionIdForUser(_user), 0);
    }

    function testTransferPositionOwnershipFailsWhenUserIsNotRegistered() public {
        address _user = address(0xdead);
        address _newAddress = address(0xacc);

        vm.startPrank(_user);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, _user));
        positionManagerF.transferPositionOwnership(_newAddress);
    }

    function testTransferPositionOwnershipEmitsEvent() public {
        address _user = address(0xdead);
        address _newAddress = address(0xacc);

        uint256 _positionId = positionManagerF.createPositionFor(_user);

        vm.startPrank(_user);
        vm.expectEmit(true, true, true, true);
        emit PositionIdTransferred(_positionId, _user, _newAddress);
        positionManagerF.transferPositionOwnership(_newAddress);
    }

    function testTransferPositionOwnershipFailsWhenNewAddressAlreadyHasPosition() public {
        address _user = address(0xdead);
        address _newAddress = address(0xacc);

        // create positions for both addresses
        uint256 _positionId1 = positionManagerF.createPositionFor(_user);
        uint256 _positionId2 = positionManagerF.createPositionFor(_newAddress);
        // ensure they are different
        assertEq(_positionId1, 1);
        assertEq(_positionId2, 2);

        vm.startPrank(_user);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_EXISTS.selector, _newAddress));
        positionManagerF.transferPositionOwnership(_newAddress);
        vm.stopPrank();
    }

    function testAdminForceTransferPosition() public {
        address _user = address(0xdead);
        address _newAddress = address(0xacc);

        uint256 _positionId = positionManagerF.createPositionFor(_user);

        vm.startPrank(address(this));
        vm.expectEmit(true, true, true, true);
        emit PositionIdTransferred(_positionId, _user, _newAddress);
        uint256 _retainedPositionId = positionManagerF.adminForceTransferPositionOwnership(_positionId, _newAddress);

        assertEq(_retainedPositionId, _positionId);
        assertEq(_newAddress, positionManagerF.getUserForPositionId(_retainedPositionId));
    }

    function testAdminForceTransferPositionFailsIfNotCalledByContractOwner() public {
        address _user = address(0xdead);
        address _newAddress = address(0xacc);

        uint256 _positionId = positionManagerF.createPositionFor(_user);

        vm.startPrank(address(_user));
        vm.expectRevert(abi.encode(ONLY_SECURITY_COUNCIL.selector));
        positionManagerF.adminForceTransferPositionOwnership(_positionId, _newAddress);
    }

    // Getters Tests
    function testGetNextPositionId() public {
        for (uint160 i = 1; i < 10; i++) {
            positionManagerF.whitelistAddress(address(i));
            positionManagerF.createPositionFor(address(i));
        }

        uint256 _nextPositionId = positionManagerF.getNextPositionId();
        assertEq(_nextPositionId, 10);
    }

    function testGetPositionIdForUser() public {
        for (uint160 i = 1; i < 10; i++) {
            positionManagerF.whitelistAddress(address(i));
            positionManagerF.createPositionFor(address(i));
        }

        uint256 _positionId3 = positionManagerF.getPositionIdForUser(address(3));
        uint256 _positionId5 = positionManagerF.getPositionIdForUser(address(5));
        uint256 _positionId10 = positionManagerF.getPositionIdForUser(address(10));

        assertEq(_positionId3, 3);
        assertEq(_positionId5, 5);
        assertEq(_positionId10, 0);
    }

    function testGetUserForPositionId() public {
        for (uint160 i = 1; i < 10; i++) {
            positionManagerF.whitelistAddress(address(i));
            positionManagerF.createPositionFor(address(i));
        }

        address _user3 = positionManagerF.getUserForPositionId(3);
        address _user5 = positionManagerF.getUserForPositionId(5);
        address _user10 = positionManagerF.getUserForPositionId(10);

        assertTrue(_user3 == address(3));
        assertTrue(_user5 == address(5));
        assertTrue(_user10 == address(0));
    }

    function testWhitelistAndBlacklistAddress() public {
        address _user = address(0x123);

        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, _user));
        positionManagerF.createPositionFor(_user);

        positionManagerF.whitelistAddress(_user);
        uint256 _positionId = positionManagerF.createPositionFor(_user);
        assertEq(_positionId, 1);

        positionManagerF.blacklistAddress(_user);
        vm.startPrank(_user);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, _user));
        positionManagerF.transferPositionOwnership(address(0x456));
        vm.stopPrank();
    }
}
