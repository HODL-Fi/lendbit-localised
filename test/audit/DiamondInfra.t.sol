// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {IDiamondCut} from "../../contracts/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "../../contracts/interfaces/IDiamondLoupe.sol";
import {IERC165} from "../../contracts/interfaces/IERC165.sol";
import {IERC173} from "../../contracts/interfaces/IERC173.sol";
import {OwnershipFacet} from "../../contracts/facets/OwnershipFacet.sol";
import {DiamondLoupeFacet} from "../../contracts/facets/DiamondLoupeFacet.sol";
import {DiamondInit} from "../../contracts/upgradeInitializers/DiamondInit.sol";

/// @dev A throwaway facet with a brand-new selector, used to exercise diamondCut Add.
contract PingFacet {
    function ping() external pure returns (uint256) {
        return 42;
    }
}

/// @notice Coverage for the EIP-2535 infrastructure facets that the audit-readiness
///         report flagged at 0%/low: OwnershipFacet, DiamondLoupeFacet, DiamondInit,
///         and the add/replace/remove + error branches in LibDiamond.
contract DiamondInfraTest is Base {
    // ---- OwnershipFacet ----
    function test_owner_is_deployer() public view {
        assertEq(OwnershipFacet(address(diamond)).owner(), address(this));
    }

    function test_transfer_ownership() public {
        address newOwner = makeAddr("newOwner");
        OwnershipFacet(address(diamond)).transferOwnership(newOwner);
        assertEq(OwnershipFacet(address(diamond)).owner(), newOwner);
    }

    function test_transfer_ownership_non_owner_reverts() public {
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(); // LibDiamond.enforceIsContractOwner
        OwnershipFacet(address(diamond)).transferOwnership(makeAddr("x"));
    }

    // ---- DiamondLoupeFacet ----
    function test_loupe_facets_and_addresses() public view {
        IDiamondLoupe.Facet[] memory facets = DiamondLoupeFacet(address(diamond)).facets();
        address[] memory addrs = DiamondLoupeFacet(address(diamond)).facetAddresses();
        assertGt(facets.length, 0, "facets populated");
        assertEq(facets.length, addrs.length, "facets and addresses align");
    }

    function test_loupe_selectors_and_address_lookup() public view {
        // owner() resolves to the ownership facet
        bytes4 ownerSel = OwnershipFacet.owner.selector;
        address ownerFacet = DiamondLoupeFacet(address(diamond)).facetAddress(ownerSel);
        assertTrue(ownerFacet != address(0), "owner() mapped to a facet");

        bytes4[] memory sels = DiamondLoupeFacet(address(diamond)).facetFunctionSelectors(ownerFacet);
        assertGt(sels.length, 0, "facet exposes selectors");

        // unknown selector maps to address(0)
        assertEq(DiamondLoupeFacet(address(diamond)).facetAddress(bytes4(0xdeadbeef)), address(0));
    }

    // ---- DiamondInit + supportsInterface ----
    function test_diamond_init_registers_erc165_interfaces() public {
        DiamondInit init = new DiamondInit();
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        IDiamondCut(address(diamond)).diamondCut(empty, address(init), abi.encodeWithSelector(DiamondInit.init.selector));

        DiamondLoupeFacet loupe = DiamondLoupeFacet(address(diamond));
        assertTrue(loupe.supportsInterface(type(IERC165).interfaceId), "ERC165");
        assertTrue(loupe.supportsInterface(type(IDiamondCut).interfaceId), "DiamondCut");
        assertTrue(loupe.supportsInterface(type(IDiamondLoupe).interfaceId), "DiamondLoupe");
        assertTrue(loupe.supportsInterface(type(IERC173).interfaceId), "ERC173");
        assertFalse(loupe.supportsInterface(bytes4(0x12345678)), "unknown interface");
    }

    // ---- LibDiamond add / replace / remove ----
    function test_diamondcut_add_new_facet() public {
        PingFacet ping = new PingFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = PingFacet.ping.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(ping),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        assertEq(PingFacet(address(diamond)).ping(), 42, "added selector callable");
        assertEq(DiamondLoupeFacet(address(diamond)).facetAddress(sels[0]), address(ping));
    }

    function test_diamondcut_replace_selector() public {
        OwnershipFacet newOwnerF = new OwnershipFacet();
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = OwnershipFacet.owner.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(newOwnerF),
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: sels
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        assertEq(DiamondLoupeFacet(address(diamond)).facetAddress(sels[0]), address(newOwnerF), "selector now points at new facet");
        // still works through the diamond
        assertEq(OwnershipFacet(address(diamond)).owner(), address(this));
    }

    function test_diamondcut_remove_selector() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = OwnershipFacet.transferOwnership.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(0),
            action: IDiamondCut.FacetCutAction.Remove,
            functionSelectors: sels
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        assertEq(DiamondLoupeFacet(address(diamond)).facetAddress(sels[0]), address(0), "selector removed");
        // calling the removed selector now reverts (no facet)
        vm.expectRevert();
        OwnershipFacet(address(diamond)).transferOwnership(makeAddr("nope"));
    }

    // ---- LibDiamond error branches ----
    function test_diamondcut_non_owner_reverts() public {
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        vm.prank(makeAddr("intruder"));
        vm.expectRevert();
        IDiamondCut(address(diamond)).diamondCut(empty, address(0), "");
    }

    function test_diamondcut_add_existing_selector_reverts() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = OwnershipFacet.owner.selector; // already registered

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(new OwnershipFacet()),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });
        vm.expectRevert(); // "Can't add function that already exists"
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");
    }
}
