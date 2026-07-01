// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {INVALID_PRICE_FEED, STALE_PRICE_FEED, TOKEN_NOT_SUPPORTED} from "../../contracts/models/Error.sol";

/// @dev A feed whose `answeredInRound` lags `roundId` — the one stale condition
///      the standard MockV3Aggregator cannot express (it always sets them equal).
contract StaleRoundFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (10, 1e8, block.timestamp, block.timestamp, 9); // answeredInRound(9) < roundId(10)
    }
}

/// @notice Coverage for the price-oracle revert branches and admin getters/setters
///         flagged low in the audit-readiness report (LibPriceOracle / PriceOracleFacet).
contract OracleCoverageTest is Base {
    // ---- _getPriceData revert branches ----
    function test_getPriceData_negative_answer_reverts() public {
        MockV3Aggregator(pricefeed1).updateAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(INVALID_PRICE_FEED.selector, pricefeed1));
        priceOracleF.getPriceData(address(token1));
    }

    function test_getPriceData_stale_by_threshold_reverts() public {
        priceOracleF.setPriceFeedStalenessThreshold(address(token1), 100);
        // refresh the feed, then let more than the threshold elapse
        MockV3Aggregator(pricefeed1).updateAnswer(1500e8);
        vm.warp(block.timestamp + 200);
        vm.expectRevert(abi.encodeWithSelector(STALE_PRICE_FEED.selector, pricefeed1));
        priceOracleF.getPriceData(address(token1));
    }

    function test_getPriceData_roundId_mismatch_reverts() public {
        StaleRoundFeed badFeed = new StaleRoundFeed();
        ERC20Mock badToken = new ERC20Mock();
        vaultManagerF.deployVault(address(badToken), address(badFeed), "xBad", "xBAD", defaultConfig);

        vm.expectRevert(abi.encodeWithSelector(STALE_PRICE_FEED.selector, address(badFeed)));
        priceOracleF.getPriceData(address(badToken));
    }

    function test_getPriceData_unsupported_token_reverts() public {
        address ghost = makeAddr("ghost");
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, ghost));
        priceOracleF.getPriceData(ghost);
    }

    // ---- _getTokenValueInUSD revert branch ----
    function test_getTokenValueInUSD_negative_answer_reverts() public {
        MockV3Aggregator(pricefeed1).updateAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(INVALID_PRICE_FEED.selector, pricefeed1));
        priceOracleF.getTokenValueInUSD(address(token1), 1 ether);
    }

    // ---- staleness threshold setter: access control ----
    function test_setStalenessThreshold_non_owner_reverts() public {
        vm.prank(makeAddr("intruder"));
        vm.expectRevert();
        priceOracleF.setPriceFeedStalenessThreshold(address(token1), 100);
    }

    // ---- Chainlink Functions admin getters/setters ----
    function test_oracle_config_getters_and_setters() public {
        priceOracleF.setupRouter(bytes32("DON"), makeAddr("router"), makeAddr("link"), 7);
        priceOracleF.setupSource("return 1");

        assertEq(priceOracleF.getSubscriptionId(), 7, "subscription id stored");
        (address router, bytes32 don) = priceOracleF.getRouterInfo();
        assertEq(router, makeAddr("router"), "router stored");
        assertEq(don, bytes32("DON"), "don id stored");
        assertEq(priceOracleF.getSource(), "return 1", "source stored");

        priceOracleF.setSubscriptionId(99);
        assertEq(priceOracleF.getSubscriptionId(), 99, "subscription id updated");
    }
}
