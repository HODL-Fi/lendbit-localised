// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {LibAppStorage} from "./LibAppStorage.sol";
import {TokenVault} from "../TokenVault.sol";
import {GlobalPoolState} from "../models/Protocol.sol";
import {Constants} from "../models/Constant.sol";
import "../models/Error.sol";
import "../models/Event.sol";

/// @title LibGlobalPool — Unified Cross-Chain LP Accounting & Valuation Library
library LibGlobalPool {
    /// @notice Process a signed off-chain aggregate report from the Global Pool Authority.
    /// @dev Updates the per-asset global pool state baseline and captures snapshots of the local vault state.
    function updateGlobalPoolState(
        LibAppStorage.StorageLayout storage s,
        address _token,
        uint256 _globalPoolValue,
        uint256 _globalShareSupply,
        uint256 _nonce,
        uint256 _deadline,
        bytes calldata _signature
    ) internal {
        if (s.s_globalPoolAuthority == address(0)) revert AUTHORITY_NOT_SET();
        if (block.timestamp > _deadline) revert EXPIRED_REPORT(_deadline, block.timestamp);

        uint256 expectedNonce = s.s_authorityNonces[_token] + 1;
        if (_nonce != expectedNonce) revert INVALID_REPORT_NONCE(expectedNonce, _nonce);

        bytes32 messageHash = keccak256(
            abi.encode(_token, _globalPoolValue, _globalShareSupply, _nonce, _deadline, block.chainid, address(this))
        );
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recovered = ECDSA.recover(ethSignedHash, _signature);

        if (recovered != s.s_globalPoolAuthority) revert INVALID_GLOBAL_POOL_AUTHORITY();

        TokenVault vault = s.i_tokenVault[_token];
        if (address(vault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        uint256 localVaultValue = vault.totalAssets();
        uint256 localShareSupply = vault.totalSupply();

        s.s_globalPoolState[_token] = GlobalPoolState({
            globalPoolValue: _globalPoolValue,
            globalShareSupply: _globalShareSupply,
            lastUpdatedTimestamp: block.timestamp,
            localSnapshotAssets: localVaultValue,
            localSnapshotShares: localShareSupply
        });

        s.s_authorityNonces[_token] = _nonce;

        emit GlobalPoolStateUpdated(_token, _globalPoolValue, _globalShareSupply, _nonce, block.timestamp);
    }

    /// @notice Get real-time unified global assets and share supply for a token,
    ///         reflecting local accrual/deltas since the last authority report.
    /// @dev Reverts with INCONSISTENT_LOCAL_STATE if current local assets or shares fall below the report snapshot.
    function getGlobalPoolState(LibAppStorage.StorageLayout storage s, address _token)
        internal
        view
        returns (uint256 currentGlobalAssets, uint256 currentGlobalShares)
    {
        GlobalPoolState storage state = s.s_globalPoolState[_token];
        TokenVault vault = s.i_tokenVault[_token];
        if (address(vault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        uint256 currentLocalAssets = vault.totalAssets();
        uint256 currentLocalShares = vault.totalSupply();

        if (state.lastUpdatedTimestamp == 0) {
            // Un-initialized / no report yet: fall back to local vault numbers
            return (currentLocalAssets, currentLocalShares);
        }

        if (currentLocalAssets < state.localSnapshotAssets || currentLocalShares < state.localSnapshotShares) {
            revert INCONSISTENT_LOCAL_STATE();
        }

        uint256 localAssetDelta = currentLocalAssets - state.localSnapshotAssets;
        uint256 localShareDelta = currentLocalShares - state.localSnapshotShares;

        currentGlobalAssets = state.globalPoolValue + localAssetDelta;
        currentGlobalShares = state.globalShareSupply + localShareDelta;
    }

    /// @notice Get current unified share price (scaled 1e18) for a token.
    function getSharePrice(LibAppStorage.StorageLayout storage s, address _token) internal view returns (uint256) {
        (uint256 currentGlobalAssets, uint256 currentGlobalShares) = getGlobalPoolState(s, _token);

        if (currentGlobalShares == 0 || currentGlobalAssets == 0) {
            return Constants.PRECISION;
        }

        return (currentGlobalAssets * Constants.PRECISION) / currentGlobalShares;
    }

    /// @notice Convert deposit assets into global pool share amount using unified price.
    function convertToShares(LibAppStorage.StorageLayout storage s, address _token, uint256 _assets)
        internal
        view
        returns (uint256)
    {
        (uint256 currentGlobalAssets, uint256 currentGlobalShares) = getGlobalPoolState(s, _token);

        if (currentGlobalShares == 0 || currentGlobalAssets == 0) {
            return _assets;
        }

        return (_assets * currentGlobalShares) / currentGlobalAssets;
    }

    /// @notice Convert global pool shares into redeemable asset amount using unified price.
    function convertToAssets(LibAppStorage.StorageLayout storage s, address _token, uint256 _shares)
        internal
        view
        returns (uint256)
    {
        (uint256 currentGlobalAssets, uint256 currentGlobalShares) = getGlobalPoolState(s, _token);

        if (currentGlobalShares == 0 || currentGlobalAssets == 0) {
            return _shares;
        }

        return (_shares * currentGlobalAssets) / currentGlobalShares;
    }
}
