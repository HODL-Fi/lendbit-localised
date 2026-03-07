// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/ReceiverFacet.sol";
import "../contracts/models/Protocol.sol";
import "../contracts/models/Error.sol";
import "../contracts/models/Event.sol";

import {Base} from "./Base.t.sol";

contract ReceiverFacetTest is Base {
    ReceiverFacet receiverF;

    function setUp() public override {
        super.setUp();

        // Deploy and add ReceiverFacet to the diamond
        ReceiverFacet receiverFacetImpl = new ReceiverFacet();
        FacetCut[] memory cut = new FacetCut[](1);
        cut[0] = FacetCut({
            facetAddress: address(receiverFacetImpl),
            action: FacetCutAction.Add,
            functionSelectors: generateSelectors("ReceiverFacet")
        });
        IDiamondCut(address(diamond)).diamondCut(cut, address(0x0), "");
        receiverF = ReceiverFacet(address(diamond));
    }

    function testOnReport() public {
        bytes memory metadata = hex"111111111111111111111111111111111111111111111111111111111111111131653834343762643462aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0001";

        bytes memory report = hex"01424f52524f570000000000000000000000000000000000000000000000000000000000000002c4e08f4e2e50eff89b476c9416f0b7b607edb71a0000000000000000000000000000000000000000000000000000000005f5e1000000000000000000000000000000000000000000000000000000000000015180000000000000000000000000000000000000000000000000000000000000a8690000000000000000000000000000000000000000000000000000000000014a340000000000000000000000000000000000000000000000000000019cc551a5ba6a4a39de0b74e3799f8ede32f7062289da3f13d845b2e6429273a98dbda127b2d769495d20770efffebde7a73b5f7d45051ced3309f0d279941256ae737280cac100537c7247e5796a620185630e24ac9efe1aa654700ab8ea48ee332624b62f65bcff4dc56363441b";

        receiverF.onReport(metadata, report);
    }
}
