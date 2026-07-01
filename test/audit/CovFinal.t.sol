// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {ADDRESS_ZERO, AMOUNT_ZERO} from "../../contracts/models/Error.sol";

contract CovFinalRouter {
    uint64 public lastSub;

    function sendRequest(uint64 sub, bytes calldata, uint16, uint32, bytes32) external returns (bytes32) {
        lastSub = sub;
        return keccak256(abi.encode(sub));
    }
}

/// @notice Final reachable-branch coverage: leftover validation branches the
///         per-file coverage agents did not reach.
contract CovFinalTest is Base {
    // LibProtocol — penalty rate zero guard
    function test_setInterestRate_zero_penalty_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_ZERO.selector));
        protocolF.setInterestRate(2000, 0);
    }

    // LibProtocol._addCollateralToken — zero price-feed guard
    function test_addCollateralToken_zero_feed_reverts() public {
        ERC20Mock t = new ERC20Mock();
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_ZERO.selector));
        protocolF.addCollateralToken(address(t), address(0), 5000);
    }

    // PriceOracleFacet.sendRequest — the args.length > 0 branch
    function test_sendRequest_with_args() public {
        CovFinalRouter router = new CovFinalRouter();
        priceOracleF.setupRouter(bytes32("DON"), address(router), makeAddr("link"), 5);
        priceOracleF.setupSource("return 1");
        positionManagerF.whitelistAddress(address(this));

        string[] memory args = new string[](2);
        args[0] = "a";
        args[1] = "b";
        priceOracleF.sendRequest(123, args); // caller id ignored; args branch taken
        assertEq(router.lastSub(), 5, "billed protocol subscription");
    }
}
