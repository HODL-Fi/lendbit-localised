// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

import {MockAavePool} from "../../contracts/mocks/MockAavePool.sol";
import {YieldStrategyConfig} from "../../contracts/models/Yield.sol";
import {Base} from "../Base.t.sol";
import "../../contracts/models/Error.sol";

/// @dev Minimal Chainlink Functions router / LINK stubs (mirrors CovMiscTail).
contract MockRouter {
    bytes32 public lastId;
    uint256 private nonce;

    function sendRequest(uint64, bytes calldata, uint16, uint32, bytes32) external returns (bytes32) {
        nonce++;
        lastId = keccak256(abi.encode(address(this), nonce));
        return lastId;
    }
}

contract MockLinkTok {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferAndCall(address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @title AuditLeads0702 — PoCs for the fixed *Leads* in
///        `lendbit-localised-pashov-ai-audit-report-20260702-150619.md`.
/// @notice Each test fails on the pre-fix code and passes on the remediated code.
///         Covers: feed-decimals underflow, oracle error-before-store, pause-blocks-
///         withdrawal, yield claim bypasses whitelist, and reconfigure erases yield.
contract AuditLeads0702Test is Base {
    // -------------------------------------------------------------------------
    //  Lead: oracle feed decimals > 18 must not DoS valuation
    // -------------------------------------------------------------------------

    /// A collateral token whose price feed reports more than 18 decimals values
    /// without reverting. Pre-fix `10 ** (18 - feedDecimals)` underflows and every
    /// valuation (borrow, health, liquidation) for the token reverts.
    function test_feed_decimals_above_18_does_not_dos_valuation() public {
        ERC20Mock _tok = new ERC20Mock(18);
        // 20-decimal feed, price $1000.
        MockV3Aggregator _feed = new MockV3Aggregator(20, int256(1000) * int256(10 ** 20));
        protocolF.addCollateralToken(address(_tok), address(_feed), 8000);

        uint256 _pid = depositCollateralFor(user1, address(_tok), 5 ether);

        // Valuation resolves instead of reverting; 5 tokens * $1000 = $5000 (1e18).
        uint256 _value = gettersF.getPositionCollateralValue(_pid);
        assertEq(_value, 5000 * 1e18, "20-decimal feed values correctly");
    }

    // -------------------------------------------------------------------------
    //  Lead: Functions error callback must not revert before storing the error
    // -------------------------------------------------------------------------

    /// An errored DON response (empty response, non-empty error) must be recorded,
    /// not revert the whole fulfillment. Pre-fix `abi.decode("", (uint256))` reverts
    /// before `res.err` is written, discarding the error and blocking the callback.
    function test_oracle_error_fulfillment_does_not_revert() public {
        MockRouter _router = new MockRouter();
        MockLinkTok _link = new MockLinkTok();
        priceOracleF.setupRouter(bytes32("DON"), address(_router), address(_link), 1);
        priceOracleF.setupSource("return 1");
        priceOracleF.setKeeper(address(this), true);

        string[] memory _args = new string[](0);
        bytes32 _reqId = priceOracleF.sendRequest(0, _args);

        // Error path: empty response, non-empty error. Must succeed (records err).
        vm.prank(address(_router));
        priceOracleF.handleOracleFulfillment(_reqId, "", bytes("DON_EXECUTION_ERROR"));
    }

    // -------------------------------------------------------------------------
    //  Lead: pausing token support must not trap LP withdrawals
    // -------------------------------------------------------------------------

    /// An LP can still withdraw their deposit while the token's support is paused;
    /// a pause blocks new deposits/borrows, it must not lock existing exits.
    function test_lp_can_withdraw_while_token_support_paused() public {
        createVaultAndFund(0); // deploys token4 vault, no deposit yet

        // user1 deposits as an LP.
        token4.mint(user1, 1000e6);
        vm.startPrank(user1);
        token4.approve(address(diamond), 1000e6);
        vaultManagerF.deposit(address(token4), 1000e6);
        vm.stopPrank();

        // Council pauses support for the token.
        vaultManagerF.pauseTokenSupport(address(token4));
        assertFalse(gettersF.tokenIsSupported(address(token4)));

        // LP exit still works (pre-fix: reverts TOKEN_NOT_SUPPORTED).
        vm.prank(user1);
        vaultManagerF.withdraw(address(token4), 400e6);
        assertEq(token4.balanceOf(user1), 400e6, "LP withdrew during pause");
    }

    // -------------------------------------------------------------------------
    //  Lead: yield claim must honour the whitelist/blacklist freeze
    // -------------------------------------------------------------------------

    /// A user blacklisted after accruing yield cannot claim it — the freeze covers
    /// every value-extracting path, not just deposit/borrow.
    function test_blacklisted_user_cannot_claim_yield() public {
        MockAavePool _pool = new MockAavePool(address(token1), token1.decimals());
        ERC20Mock _aToken = _pool.aToken();
        yieldStrategyF.configureYieldToken(address(token1), address(_pool), address(_aToken), 4000, 1500);

        // user1 deposits collateral -> allocation supplied to Aave.
        uint256 _pid = depositCollateralFor(user1, address(token1), 1000 ether);
        _pid; // silence
        _pool.simulateYield(address(diamond), 100 ether); // accrue yield

        // Council blacklists user1.
        positionManagerF.blacklistAddress(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, user1));
        yieldStrategyF.claimYield(address(token1), 0, user1);
    }

    // -------------------------------------------------------------------------
    //  Lead: reconfiguring a live yield token must distribute pending yield
    // -------------------------------------------------------------------------

    /// Yield accrued under the old parameters is credited (via `_accrueYield`)
    /// before a reconfigure rebaselines `lastRecordedBalance`. Pre-fix the pending
    /// delta is silently erased when the balance baseline jumps to current.
    function test_reconfigure_distributes_pending_yield() public {
        MockAavePool _pool = new MockAavePool(address(token1), token1.decimals());
        ERC20Mock _aToken = _pool.aToken();
        yieldStrategyF.configureYieldToken(address(token1), address(_pool), address(_aToken), 4000, 1500);

        depositCollateralFor(user1, address(token1), 1000 ether);
        _pool.simulateYield(address(diamond), 100 ether); // 100 aToken yield pending

        // user's pending yield is visible before the reconfigure.
        vm.prank(user1);
        uint256 _pendingBefore = yieldStrategyF.getPendingYield(address(token1));
        assertGt(_pendingBefore, 0, "yield accrued and pending");

        // Reconfigure the SAME token with a different protocol share.
        yieldStrategyF.configureYieldToken(address(token1), address(_pool), address(_aToken), 4000, 3000);

        // Pending yield survived the reconfigure (it was accrued into the index),
        // instead of being erased by the balance rebaseline.
        vm.prank(user1);
        uint256 _pendingAfter = yieldStrategyF.getPendingYield(address(token1));
        assertEq(_pendingAfter, _pendingBefore, "pending yield preserved across reconfigure");
    }

    // -------------------------------------------------------------------------
    //  Lead: ERC20 collateral deposit must reject accompanying ETH
    // -------------------------------------------------------------------------

    /// Sending ETH alongside an ERC20 collateral deposit reverts instead of
    /// silently trapping the ETH in the diamond.
    function test_erc20_collateral_deposit_rejects_eth() public {
        token1.mint(user1, 10 ether);
        vm.deal(user1, 1 ether);
        vm.startPrank(user1);
        token1.approve(address(diamond), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_MISMATCH.selector, uint256(1 ether), uint256(0)));
        protocolF.depositCollateral{value: 1 ether}(address(token1), 10 ether);
        vm.stopPrank();
    }
}
