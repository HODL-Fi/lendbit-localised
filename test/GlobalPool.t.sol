// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";
import {GlobalPoolAuthoritySet, GlobalPoolStateUpdated} from "../contracts/models/Event.sol";
import {
    INVALID_GLOBAL_POOL_AUTHORITY,
    AUTHORITY_NOT_SET,
    ONLY_SECURITY_COUNCIL,
    EXPIRED_REPORT,
    INVALID_REPORT_NONCE,
    INCONSISTENT_LOCAL_STATE,
    ADDRESS_ZERO,
    TOKEN_NOT_SUPPORTED
} from "../contracts/models/Error.sol";
import {TokenVault} from "../contracts/TokenVault.sol";

contract GlobalPoolTest is Base {
    uint256 internal authorityPrivateKey = 0xA11CE;
    address internal authorityAddress;

    address internal invalidSignerAddress;
    uint256 internal invalidPrivateKey = 0xBAD;

    address internal vault1;

    function setUp() public override {
        super.setUp();
        authorityAddress = vm.addr(authorityPrivateKey);
        invalidSignerAddress = vm.addr(invalidPrivateKey);

        // Deploy vault for token1
        vault1 = vaultManagerF.deployVault(address(token1), pricefeed1, "xToken1", "xTK1", defaultConfig);
    }

    function _signReport(
        address token,
        uint256 globalPoolValue,
        uint256 globalShareSupply,
        uint256 nonce,
        uint256 deadline,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encode(
                token,
                globalPoolValue,
                globalShareSupply,
                nonce,
                deadline,
                block.chainid,
                address(diamond)
            )
        );
        bytes32 ethSignedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    // ── Step 1: Storage Layout & Authority Administration Tests ─────────────

    function test_SetGlobalPoolAuthority_Success() public {
        // Verify initial authority state is zero address
        assertEq(vaultManagerF.getGlobalPoolAuthority(), address(0));

        vm.expectEmit(true, true, true, true);
        emit GlobalPoolAuthoritySet(address(0), authorityAddress);

        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        // Verify updated state
        assertEq(vaultManagerF.getGlobalPoolAuthority(), authorityAddress);
        assertEq(vaultManagerF.getAuthorityNonce(address(token1)), 0);
    }

    function test_SetGlobalPoolAuthority_ReplacesExistingAuthority() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);
        assertEq(vaultManagerF.getGlobalPoolAuthority(), authorityAddress);

        address newAuth = address(0x2222);
        vm.expectEmit(true, true, true, true);
        emit GlobalPoolAuthoritySet(authorityAddress, newAuth);

        vaultManagerF.setGlobalPoolAuthority(newAuth);
        assertEq(vaultManagerF.getGlobalPoolAuthority(), newAuth);
    }

    function test_SetGlobalPoolAuthority_RevertsIfZeroAddress() public {
        vm.expectRevert(ADDRESS_ZERO.selector);
        vaultManagerF.setGlobalPoolAuthority(address(0));
    }

    function test_SetGlobalPoolAuthority_RevertsIfNotCouncil() public {
        vm.prank(user1);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);
    }

    function test_GetAuthorityNonce_DefaultsToZero() view public {
        assertEq(vaultManagerF.getAuthorityNonce(address(token1)), 0);
    }

    // ── Step 2: Signature Verification & Report Ingestion Tests ─────────────

    function test_UpdateGlobalPoolState_Success() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        uint256 poolValue = 1_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);

        vm.expectEmit(true, true, true, true);
        emit GlobalPoolStateUpdated(address(token1), poolValue, shareSupply, nonce, block.timestamp);

        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);

        assertEq(vaultManagerF.getAuthorityNonce(address(token1)), 1);
    }

    function test_UpdateGlobalPoolState_RevertsIfAuthorityNotSet() public {
        uint256 poolValue = 1_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);

        vm.expectRevert(AUTHORITY_NOT_SET.selector);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);
    }

    function test_UpdateGlobalPoolState_RevertsIfInvalidSignature() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        uint256 poolValue = 1_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory badSig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, invalidPrivateKey);

        vm.expectRevert(INVALID_GLOBAL_POOL_AUTHORITY.selector);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, badSig);
    }

    function test_UpdateGlobalPoolState_RevertsIfExpiredTimestamp() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        uint256 poolValue = 1_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp - 1;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);

        vm.expectRevert(abi.encodeWithSelector(EXPIRED_REPORT.selector, deadline, block.timestamp));
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);
    }

    function test_UpdateGlobalPoolState_RevertsIfNonceOutOfOrder() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        uint256 poolValue = 1_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 2; // Expected 1
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);

        vm.expectRevert(abi.encodeWithSelector(INVALID_REPORT_NONCE.selector, 1, 2));
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);
    }

    function test_UpdateGlobalPoolState_RevertsIfNonceReused() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        uint256 poolValue = 1_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);

        // Try reusing nonce 1
        vm.expectRevert(abi.encodeWithSelector(INVALID_REPORT_NONCE.selector, 2, 1));
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);
    }

    // ── Step 3: Share Price & Local Delta Accrual Tests ───────────────────────

    function test_SharePrice_BeforeFirstReport() view public {
        uint256 price = vaultManagerF.getGlobalSharePrice(address(token1));
        assertEq(price, 1e18);
    }

    function test_SharePrice_AfterReport_NoLocalActivity() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        // Global pool value = 2,000,000, Share supply = 1,000,000 => Share price = 2.0
        uint256 poolValue = 2_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);

        uint256 price = vaultManagerF.getGlobalSharePrice(address(token1));
        assertEq(price, 2e18);
    }

    function test_SharePrice_AccruesLocalDelta() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        // 1. Initial deposit of 10,000 token1 into vault
        token1.mint(address(this), 10_000 ether);
        token1.approve(address(diamond), 10_000 ether);
        vaultManagerF.deposit(address(token1), 10_000 ether);

        // 2. Post report at baseline (local assets = 10,000 ether, local shares = 10,000 ether)
        // Global assets = 100,000 ether, Global shares = 100,000 ether
        uint256 poolValue = 100_000 ether;
        uint256 shareSupply = 100_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);

        // Initial price = 1.0 (1e18)
        assertEq(vaultManagerF.getGlobalSharePrice(address(token1)), 1e18);

        // 3. Local vault accrues 10,000 ether in interest (donated to vault directly)
        token1.mint(vault1, 10_000 ether);

        // Local assets = 20,000 ether, local shares = 10,000 ether
        // Local asset delta = +10,000 ether
        // Global assets = 100,000 + 10,000 = 110,000 ether
        // Global shares = 100,000 ether
        // Unified share price = 110,000 / 100,000 = 1.1 (1.1e18)
        assertEq(vaultManagerF.getGlobalSharePrice(address(token1)), 1.1e18);
    }

    // ── Step 4: Deposit & Withdraw Integration Tests ─────────────────────────

    function test_Deposit_UsesUnifiedSharePrice() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        // Post report: Global pool value = 2,000,000 ether, Share supply = 1,000,000 ether
        // Global share price = 2.0 (1 share = 2 assets)
        uint256 poolValue = 2_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);

        // User1 deposits 1,000 ether of token1
        token1.mint(user1, 1000 ether);
        vm.startPrank(user1);
        token1.approve(address(diamond), 1000 ether);
        uint256 mintedShares = vaultManagerF.deposit(address(token1), 1000 ether);
        vm.stopPrank();

        // 1,000 assets @ price 2.0 = 500 shares minted
        assertEq(mintedShares, 500 ether);
        assertEq(TokenVault(payable(vault1)).balanceOf(user1), 500 ether);
    }

    function test_Withdraw_UsesUnifiedSharePrice() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        // Post report: Global share price = 2.0 (1 share = 2 assets)
        uint256 poolValue = 2_000_000 ether;
        uint256 shareSupply = 1_000_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);

        // User1 deposits 1,000 ether of token1 -> receives 500 shares
        token1.mint(user1, 1000 ether);
        vm.startPrank(user1);
        token1.approve(address(diamond), 1000 ether);
        vaultManagerF.deposit(address(token1), 1000 ether);

        TokenVault vaultContract = TokenVault(payable(vault1));

        uint256 userSharesBefore = vaultContract.balanceOf(user1);
        uint256 totalSharesBefore = vaultContract.totalSupply();
        assertEq(userSharesBefore, 500 ether);

        // User1 withdraws 1,000 ether of token1 -> 500 shares should be burned
        vaultManagerF.withdraw(address(token1), 1000 ether);
        vm.stopPrank();

        uint256 userSharesAfter = vaultContract.balanceOf(user1);
        uint256 totalSharesAfter = vaultContract.totalSupply();

        // Verify exact share burn amounts
        assertEq(userSharesAfter, 0);
        assertEq(userSharesBefore - userSharesAfter, 500 ether);
        assertEq(totalSharesBefore - totalSharesAfter, 500 ether);
        assertEq(token1.balanceOf(user1), 1000 ether);
    }

    // ── Phase 0 System Invariant Tests ────────────────────────────────────────

    /// @notice Invariant 1: getGlobalSharePrice(token) > 0 for any initialized pool with non-zero assets & shares.
    function test_Invariant_1_PositiveSharePrice() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        uint256 poolValue = 500_000 ether;
        uint256 shareSupply = 250_000 ether;
        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signReport(address(token1), poolValue, shareSupply, nonce, deadline, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), poolValue, shareSupply, nonce, deadline, sig);

        uint256 price = vaultManagerF.getGlobalSharePrice(address(token1));
        assertTrue(price > 0, "Share price must be positive");
        assertEq(price, 2e18, "Share price must equal globalAssets / globalShares");
    }

    /// @notice Invariant 2: Monotonic nonces — s_authorityNonces[token] increases strictly on valid reports (expecting current + 1).
    function test_Invariant_2_StrictlyMonotonicNonces() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        assertEq(vaultManagerF.getAuthorityNonce(address(token1)), 0);

        // Valid report 1 at nonce 1
        bytes memory sig1 = _signReport(address(token1), 1_000_000 ether, 1_000_000 ether, 1, block.timestamp + 1 hours, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), 1_000_000 ether, 1_000_000 ether, 1, block.timestamp + 1 hours, sig1);
        assertEq(vaultManagerF.getAuthorityNonce(address(token1)), 1);

        // Valid report 2 at nonce 2
        bytes memory sig2 = _signReport(address(token1), 1_200_000 ether, 1_000_000 ether, 2, block.timestamp + 1 hours, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), 1_200_000 ether, 1_000_000 ether, 2, block.timestamp + 1 hours, sig2);
        assertEq(vaultManagerF.getAuthorityNonce(address(token1)), 2);

        // Replay report 1 -> reverts
        vm.expectRevert(abi.encodeWithSelector(INVALID_REPORT_NONCE.selector, 3, 1));
        vaultManagerF.updateGlobalPoolState(address(token1), 1_000_000 ether, 1_000_000 ether, 1, block.timestamp + 1 hours, sig1);
    }

    /// @notice Invariant 3: Conservation of LP Share Value across unified price changes.
    function test_Invariant_3_ConservationOfLpShareValue() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        // Price = 2.0 (1 share = 2 assets)
        bytes memory sig1 = _signReport(address(token1), 2_000_000 ether, 1_000_000 ether, 1, block.timestamp + 1 hours, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), 2_000_000 ether, 1_000_000 ether, 1, block.timestamp + 1 hours, sig1);

        uint256 assets = 1000 ether;
        uint256 shares = vaultManagerF.convertToGlobalShares(address(token1), assets);
        assertEq(shares, 500 ether);

        uint256 convertedBack = vaultManagerF.convertToGlobalAssets(address(token1), shares);
        assertEq(convertedBack, assets, "Converted assets must equal original asset input");
    }

    /// @notice Invariant 4: Circuit Breaker Revert — INCONSISTENT_LOCAL_STATE() fires if current local assets/shares drop below snapshot.
    function test_Invariant_4_CircuitBreakerRevertOnUnderflow() public {
        vaultManagerF.setGlobalPoolAuthority(authorityAddress);

        // 1. User deposits 1,000 ether into vault
        token1.mint(address(this), 1000 ether);
        token1.approve(address(diamond), 1000 ether);
        vaultManagerF.deposit(address(token1), 1000 ether);

        // 2. Post report snapshotting local assets = 1000 ether, local shares = 1000 ether
        bytes memory sig = _signReport(address(token1), 100_000 ether, 100_000 ether, 1, block.timestamp + 1 hours, authorityPrivateKey);
        vaultManagerF.updateGlobalPoolState(address(token1), 100_000 ether, 100_000 ether, 1, block.timestamp + 1 hours, sig);

        // Price works fine at baseline
        assertEq(vaultManagerF.getGlobalSharePrice(address(token1)), 1e18);

        // 3. Simulate unexpected asset drop in local vault (e.g. forced burn/transfer out)
        vm.prank(address(diamond));
        TokenVault(payable(vault1)).withdraw(500 ether, user1, address(this));

        // 4. Querying global share price now reverts with INCONSISTENT_LOCAL_STATE instead of underflowing/corrupting price
        vm.expectRevert(INCONSISTENT_LOCAL_STATE.selector);
        vaultManagerF.getGlobalSharePrice(address(token1));
    }

    /// @notice Invariant 5: Baseline Fallback — If lastUpdatedTimestamp == 0, pricing falls back to local vault without reverting.
    function test_Invariant_5_BaselineFallbackUninitialized() view public {
        // No authority report has been posted yet
        uint256 price = vaultManagerF.getGlobalSharePrice(address(token1));
        assertEq(price, 1e18, "Uninitialized pool must fall back to 1e18 baseline");

        uint256 shares = vaultManagerF.convertToGlobalShares(address(token1), 1000 ether);
        assertEq(shares, 1000 ether, "Uninitialized pool must fall back to 1:1 shares");

        uint256 assets = vaultManagerF.convertToGlobalAssets(address(token1), 1000 ether);
        assertEq(assets, 1000 ether, "Uninitialized pool must fall back to 1:1 assets");
    }
}
