// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {IDiamondCut} from "../../contracts/interfaces/IDiamondCut.sol";
import {LibDiamond} from "../../contracts/libraries/LibDiamond.sol";
import {OwnershipFacet} from "../../contracts/facets/OwnershipFacet.sol";
import {DiamondLoupeFacet} from "../../contracts/facets/DiamondLoupeFacet.sol";

/// @dev Throwaway facet supplying a brand-new selector for Add/Replace exercises.
contract CovPingFacet {
    function covPing() external pure returns (uint256) {
        return 7;
    }
}

/// @dev Initializer whose delegatecall succeeds (no-op) — exercises the success leg of initializeDiamondCut.
contract GoodInit {
    function ok() external {}
}

/// @dev Initializer whose delegatecall reverts with empty returndata — exercises InitCallFailed.
contract RevertingInit {
    function boom() external pure {
        revert();
    }
}

/// @notice Branch coverage for the remaining LibDiamond revert paths not covered by DiamondInfra.t.sol.
///         DiamondInfra already covers: Add success, Replace success, Remove success, non-owner revert,
///         and add-duplicate (SelectorExists). This file covers every other reachable branch.
contract CovLibDiamondTest is Base {
    IDiamondCut cut_;

    function setUp() public override {
        super.setUp();
        cut_ = IDiamondCut(address(diamond));
    }

    function _one(bytes4 s) internal pure returns (bytes4[] memory a) {
        a = new bytes4[](1);
        a[0] = s;
    }

    function _cut(address facet, IDiamondCut.FacetCutAction action, bytes4[] memory sels)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory c)
    {
        c = new IDiamondCut.FacetCut[](1);
        c[0] = IDiamondCut.FacetCut({facetAddress: facet, action: action, functionSelectors: sels});
    }

    // ---- addFunctions branches ----

    // facetAddress == address(0) with non-empty selectors → NoZeroAddress
    function test_add_zero_facet_reverts_NoZeroAddress() public {
        IDiamondCut.FacetCut[] memory c = _cut(address(0), IDiamondCut.FacetCutAction.Add, _one(bytes4(0x11111111)));
        vm.expectRevert(LibDiamond.NoZeroAddress.selector);
        cut_.diamondCut(c, address(0), "");
    }

    // empty functionSelectors array → NoSelectorsInFacet (length check is first in addFunctions)
    function test_add_empty_selectors_reverts_NoSelectorsInFacet() public {
        CovPingFacet ping = new CovPingFacet();
        IDiamondCut.FacetCut[] memory c =
            _cut(address(ping), IDiamondCut.FacetCutAction.Add, new bytes4[](0));
        vm.expectRevert(LibDiamond.NoSelectorsInFacet.selector);
        cut_.diamondCut(c, address(0), "");
    }

    // facet address with no code → NoCode (via addFacet → enforceHasContractCode)
    function test_add_facet_with_no_code_reverts_NoCode() public {
        address eoa = makeAddr("eoaFacet");
        IDiamondCut.FacetCut[] memory c = _cut(eoa, IDiamondCut.FacetCutAction.Add, _one(bytes4(0x22222222)));
        vm.expectRevert(LibDiamond.NoCode.selector);
        cut_.diamondCut(c, address(0), "");
    }

    // ---- replaceFunctions branches ----

    // replace a selector with the SAME facet it already points to → SameSelectorReplacement
    function test_replace_same_facet_reverts_SameSelectorReplacement() public {
        bytes4 ownerSel = OwnershipFacet.owner.selector;
        address currentFacet = DiamondLoupeFacet(address(diamond)).facetAddress(ownerSel);
        assertTrue(currentFacet != address(0), "owner() must be mapped");

        IDiamondCut.FacetCut[] memory c =
            _cut(currentFacet, IDiamondCut.FacetCutAction.Replace, _one(ownerSel));
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.SameSelectorReplacement.selector, ownerSel));
        cut_.diamondCut(c, address(0), "");
    }

    // replace a selector that does not exist yet → NonExistentSelector (removeFunction sees facet 0)
    function test_replace_nonexistent_selector_reverts_NonExistentSelector() public {
        CovPingFacet ping = new CovPingFacet();
        bytes4 sel = CovPingFacet.covPing.selector;
        IDiamondCut.FacetCut[] memory c = _cut(address(ping), IDiamondCut.FacetCutAction.Replace, _one(sel));
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NonExistentSelector.selector, sel));
        cut_.diamondCut(c, address(0), "");
    }

    // ---- removeFunctions branches ----

    // remove with facetAddress != address(0) → MustBeZeroAddress
    function test_remove_nonzero_facet_reverts_MustBeZeroAddress() public {
        IDiamondCut.FacetCut[] memory c =
            _cut(address(this), IDiamondCut.FacetCutAction.Remove, _one(OwnershipFacet.owner.selector));
        vm.expectRevert(LibDiamond.MustBeZeroAddress.selector);
        cut_.diamondCut(c, address(0), "");
    }

    // remove a selector that does not exist → NonExistentSelector
    function test_remove_nonexistent_selector_reverts_NonExistentSelector() public {
        bytes4 sel = bytes4(0x33333333);
        IDiamondCut.FacetCut[] memory c = _cut(address(0), IDiamondCut.FacetCutAction.Remove, _one(sel));
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.NonExistentSelector.selector, sel));
        cut_.diamondCut(c, address(0), "");
    }

    // immutable function (selector mapped to the diamond itself) → ImmutableFunction on removal
    function test_remove_immutable_function_reverts_ImmutableFunction() public {
        bytes4 sel = bytes4(0x44444444);

        // Step 1: add a selector pointing at the diamond (address(this) inside LibDiamond).
        IDiamondCut.FacetCut[] memory addCut =
            _cut(address(diamond), IDiamondCut.FacetCutAction.Add, _one(sel));
        cut_.diamondCut(addCut, address(0), "");

        // Step 2: removing it hits the address(this) immutable guard.
        IDiamondCut.FacetCut[] memory rmCut = _cut(address(0), IDiamondCut.FacetCutAction.Remove, _one(sel));
        vm.expectRevert(abi.encodeWithSelector(LibDiamond.ImmutableFunction.selector, sel));
        cut_.diamondCut(rmCut, address(0), "");
    }

    // ---- initializeDiamondCut branches ----

    // _init != 0 but empty calldata → EmptyCalldata
    function test_init_nonzero_empty_calldata_reverts_EmptyCalldata() public {
        GoodInit init = new GoodInit();
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(LibDiamond.EmptyCalldata.selector);
        cut_.diamondCut(empty, address(init), "");
    }

    // _init == 0 but non-empty calldata → NonEmptyCalldata
    function test_init_zero_nonempty_calldata_reverts_NonEmptyCalldata() public {
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(LibDiamond.NonEmptyCalldata.selector);
        cut_.diamondCut(empty, address(0), hex"1234");
    }

    // _init set to an address with no code → NoCode (enforceHasContractCode in init path)
    function test_init_no_code_reverts_NoCode() public {
        address eoa = makeAddr("eoaInit");
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(LibDiamond.NoCode.selector);
        cut_.diamondCut(empty, eoa, hex"1234");
    }

    // _init points at a contract whose delegatecall reverts with no data → InitCallFailed
    function test_init_call_failed_reverts_InitCallFailed() public {
        RevertingInit init = new RevertingInit();
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(LibDiamond.InitCallFailed.selector);
        cut_.diamondCut(empty, address(init), abi.encodeWithSelector(RevertingInit.boom.selector));
    }

    // successful init delegatecall → covers the success leg of initializeDiamondCut
    function test_init_success_path() public {
        GoodInit init = new GoodInit();
        IDiamondCut.FacetCut[] memory empty = new IDiamondCut.FacetCut[](0);
        cut_.diamondCut(empty, address(init), abi.encodeWithSelector(GoodInit.ok.selector));
        // no revert == success path executed
    }

    // ---- ownership NoZeroAddress (setContractOwner) ----
    function test_transfer_ownership_zero_reverts_NoZeroAddress() public {
        vm.expectRevert(LibDiamond.NoZeroAddress.selector);
        OwnershipFacet(address(diamond)).transferOwnership(address(0));
    }
}
