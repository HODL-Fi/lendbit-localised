// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Base} from "../Base.t.sol";

import "../../contracts/models/Protocol.sol";
import "../../contracts/models/Error.sol";

/// @title AuditReport0702 — PoCs for the confirmed findings in
///        `lendbit-localised-pashov-ai-audit-report-20260702-150619.md`.
/// @notice Covers report findings #2 (LTV can exceed liquidation threshold),
///         #3 (bad-debt writeoff leaves utilization borrow accounting stale),
///         and #7 (cross-user borrow nonces share one global namespace). Each
///         test fails on the pre-fix code and passes on the remediated code.
contract AuditReport0702Test is Base {
    uint256 internal constant SIGNER_KEY = 0xA11CE;

    function setUp() public override {
        super.setUp();
    }

    // -------------------------------------------------------------------------
    //  #2 — LTV must never exceed the collateral's liquidation threshold
    // -------------------------------------------------------------------------

    /// Onboarding an LTV above the default 90% threshold is rejected: otherwise a
    /// borrower could open a position at `LTV·C` that is already past the
    /// `threshold·C` liquidation trigger — healthy yet instantly liquidatable.
    function test_addCollateralToken_rejects_ltv_above_threshold() public {
        (address _tok, address _feed) = deployERC20ContractAndAddPriceFeed("HiLTV", 18, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(LTV_ABOVE_LIQUIDATION_THRESHOLD.selector, uint16(9500), uint16(9000))
        );
        protocolF.addCollateralToken(_tok, _feed, 9500);
    }

    /// The LTV setter enforces the same invariant against the live effective
    /// threshold — raising token1's LTV above its 90% threshold reverts.
    function test_setCollateralTokenLtv_rejects_ltv_above_threshold() public {
        // token1 onboarded at LTV 8000, threshold defaults to 9000.
        vm.expectRevert(
            abi.encodeWithSelector(LTV_ABOVE_LIQUIDATION_THRESHOLD.selector, uint16(9500), uint16(9000))
        );
        protocolF.setCollateralTokenLtv(address(token1), 9500);
    }

    /// The invariant composes with the per-asset threshold knob: widen the
    /// threshold first, then the higher LTV is admissible.
    function test_ltv_setter_composes_with_threshold_widening() public {
        protocolF.setCollateralLiquidationThreshold(address(token1), 9600);
        protocolF.setCollateralTokenLtv(address(token1), 9500); // now <= threshold
        assertEq(gettersF.getCollateralTokenLTV(address(token1)), 9500);
    }

    // -------------------------------------------------------------------------
    //  #3 — bad-debt writeoff must clear the diamond-side utilization tally
    // -------------------------------------------------------------------------

    /// A socialized bad-debt writeoff must decrement `config.totalBorrows`, not
    /// only the vault's internal `totalBorrows`. Leaving the config counter
    /// inflated keeps utilization permanently high and bricks new borrows.
    function test_writeOffBadDebt_reduces_config_totalBorrows() public {
        createVaultAndFund(1_000_000e6);

        // user1 opens an open-ended borrow so config.totalBorrows == principal.
        depositCollateralFor(user1, address(token1), 100 ether); // $150k collateral
        uint256 _borrow = 100e6; // 100 token4 @ $250 = $25k, well within $120k borrowable
        vm.prank(user1);
        protocolF.borrow(address(token4), _borrow);

        VaultConfiguration memory _cfgBefore = vaultManagerF.getTokenVaultConfig(address(token4));
        assertEq(_cfgBefore.totalBorrows, _borrow, "config borrows == principal after borrow");

        // Council socializes part of the principal as bad debt.
        uint256 _badDebt = 40e6;
        vaultManagerF.writeOffBadDebt(address(token4), _badDebt);

        VaultConfiguration memory _cfgAfter = vaultManagerF.getTokenVaultConfig(address(token4));
        // Pre-fix: _cfgAfter.totalBorrows would still equal `_borrow` (stale).
        assertEq(
            _cfgAfter.totalBorrows,
            _borrow - _badDebt,
            "config borrows must drop by the written-off amount"
        );
    }

    // -------------------------------------------------------------------------
    //  #7 — request-borrow nonces are per-wallet, not one global namespace
    // -------------------------------------------------------------------------

    /// Two different wallets can each use nonce 1: the namespace is keyed by
    /// wallet, so one wallet's nonce can no longer block another's. Pre-fix the
    /// second wallet's request reverts REQUEST_BORROW_NONCE_USED.
    function test_requestBorrow_nonce_is_per_wallet() public {
        createVaultAndFund(1_000_000e6);
        positionManagerF.setRequestBorrowSigner(vm.addr(SIGNER_KEY));

        uint256 _posA = depositCollateralFor(user1, address(token1), 100 ether);
        uint256 _posB = depositCollateralFor(user2, address(token1), 100 ether);

        BorrowRequest memory _reqA = _nonceRequest(_posA, user1, 1);
        BorrowRequest memory _reqB = _nonceRequest(_posB, user2, 1); // same nonce, different wallet

        vm.prank(user1);
        protocolF.requestBorrow(_reqA, _sign(_reqA, SIGNER_KEY));

        // Second wallet, identical nonce — must succeed (independent namespace).
        vm.prank(user2);
        protocolF.requestBorrow(_reqB, _sign(_reqB, SIGNER_KEY));

        // Same (wallet, nonce) replay is still blocked.
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(REQUEST_BORROW_NONCE_USED.selector, user1, uint256(1)));
        protocolF.requestBorrow(_reqA, _sign(_reqA, SIGNER_KEY));
    }

    // -------------------------------------------------------------------------
    //  helpers
    // -------------------------------------------------------------------------

    function _nonceRequest(uint256 _positionId, address _wallet, uint256 _nonce)
        internal
        view
        returns (BorrowRequest memory)
    {
        return BorrowRequest({
            action: "BORROW_REQUEST",
            positionId: _positionId,
            token: address(token4),
            amount: 1000 * 1e6,
            tenureSeconds: 30 days,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: _nonce,
            contractAddress: address(protocolF),
            wallet: _wallet,
            deadline: 0
        });
    }

    function _sign(BorrowRequest memory _request, uint256 _key) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _request.action,
                _request.positionId,
                _request.token,
                _request.amount,
                _request.tenureSeconds,
                _request.sourceChainId,
                _request.targetChainId,
                _request.nonce,
                _request.contractAddress,
                _request.wallet,
                _request.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, MessageHashUtils.toEthSignedMessageHash(messageHash));
        return abi.encodePacked(r, s, v);
    }
}
