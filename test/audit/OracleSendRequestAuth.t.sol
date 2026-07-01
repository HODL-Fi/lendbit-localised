// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {ADDRESS_NOT_WHITELISTED} from "../../contracts/models/Error.sol";

/// @dev Minimal Chainlink Functions router that "bills" LINK by counting each
///      request against the subscription id it is handed. Lets us prove who pays.
contract MockFunctionsRouter {
    mapping(uint64 => uint256) public callsBilledTo; // subscriptionId -> LINK charges
    uint64 public lastSubscriptionId;
    uint256 private _nonce;

    function sendRequest(uint64 subscriptionId, bytes calldata, uint16, uint32, bytes32)
        external
        returns (bytes32)
    {
        callsBilledTo[subscriptionId] += 1; // each request charges this subscription
        lastSubscriptionId = subscriptionId;
        return keccak256(abi.encode(subscriptionId, _nonce++));
    }
}

/// @notice Finding #2: `sendRequest` was unauthenticated and forwarded a
///         caller-supplied subscriptionId, letting anyone drain the protocol's
///         Chainlink LINK subscription. Refresh is keeper-triggered, so the fix
///         gates on the keeper whitelist and forces the stored subscription id.
contract OracleSendRequestAuthTest is Base {
    MockFunctionsRouter router;

    uint64 constant PROTOCOL_SUB = 4242; // the protocol's real, publicly-readable subscription
    uint64 constant ATTACKER_SUB = 9999; // some other subscription the attacker might name

    address keeper = makeAddr("keeper");
    address attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        router = new MockFunctionsRouter();
        // owner (address(this)) wires the router + source and registers the protocol subscription
        priceOracleF.setupRouter(bytes32("DON"), address(router), makeAddr("link"), PROTOCOL_SUB);
        priceOracleF.setupSource("return Functions.encodeUint256(1)");
    }

    /// @dev The fix: a non-whitelisted attacker can no longer trigger a refresh.
    function test_attacker_cannot_send_request() public {
        string[] memory args = new string[](0);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, attacker));
        priceOracleF.sendRequest(ATTACKER_SUB, args);

        assertEq(router.callsBilledTo(PROTOCOL_SUB), 0, "no LINK should have been billed");
    }

    /// @dev The whitelisted keeper can refresh, and the caller-supplied id is
    ///      ignored in favour of the protocol's own subscription.
    function test_keeper_refresh_uses_protocol_subscription() public {
        positionManagerF.whitelistAddress(keeper);

        string[] memory args = new string[](0);
        // keeper passes a bogus subscription id; the hub must ignore it
        vm.prank(keeper);
        priceOracleF.sendRequest(ATTACKER_SUB, args);

        assertEq(router.callsBilledTo(ATTACKER_SUB), 0, "caller-supplied id must be ignored");
        assertEq(router.callsBilledTo(PROTOCOL_SUB), 1, "request billed to the protocol's own subscription");
    }
}
