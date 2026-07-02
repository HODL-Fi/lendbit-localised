// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFunctionsRouter} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsRouter.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import {TokenVault} from "../TokenVault.sol";

import "../models/Protocol.sol";
import "../models/Yield.sol";

/// @title LibAppStorage — Diamond shared-storage layout and accessor for the lending protocol
library LibAppStorage {
    struct StorageLayout {
        IFunctionsRouter i_router;
        LinkTokenInterface i_linkToken;
        uint256 s_nextPositionId;
        uint256 s_nextLoanId;
        uint16 s_interestRate;
        uint16 s_penaltyRate;
        mapping(uint256 => address) s_positionOwner; // PositionID -> Owner Address
        mapping(address => uint256) s_ownerPosition; // Owner Address -> PositionID
        mapping(bytes32 => uint256) s_requestIdToBorrowId; // Chainlink RequestID -> BorrowID

        // borrowable token related storage
        address[] s_allSupportedTokens;
        mapping(address => bool) s_supportedToken;
        mapping(string => address) s_localCurrencyToToken; // currency string -> token address
        mapping(address => address) s_tokenPriceFeed; // token address -> price feed address
        mapping(address => TokenVault) i_tokenVault;
        mapping(address => VaultConfiguration) s_tokenVaultConfig; // token address -> vault config

        // collateral tracking
        mapping(uint256 => mapping(address => uint256)) s_positionCollateral; // PositionID -> (Token Address -> Amount)
        mapping(address => bool) s_supportedCollateralTokens;
        mapping(address => uint16) s_collateralTokenLTV;
        address[] s_allCollateralTokens; // list of all collateral tokens

        // borrow tracking
        mapping(uint256 => mapping(address => uint256)) s_positionBorrowed; // PositionID -> (token address -> Amount)
        mapping(uint256 => mapping(address => uint256)) s_positionBorrowedLastUpdate; // PositionID -> (token address -> timestamp)

        // tenured loans tracking
        mapping(uint256 => Loan) s_loans; // loanId -> Loan struct
        mapping(uint256 => uint256[]) s_positionActiveLoanIds; // positionId -> list of loanIds
        mapping(uint256 => uint256[]) s_positionClosedLoanIds; // positionId -> list of closed loanIds

        // yield strategy state
        mapping(address => YieldStrategyConfig) s_yieldConfigs; // collateral token -> yield config
        mapping(uint256 => mapping(address => YieldPosition)) s_positionYield; // positionId -> (token -> yield position)
        mapping(address => bool) s_yieldApprovals; // collateral token -> approval flag for Aave pool

        mapping(address => bool) isWhitelisted; // address -> whitelist status

        address s_requestBorrowSigner;
        mapping(address => mapping(uint256 => bool)) s_requestBorrowNonceUsed;

        // Chainlink functions variables
        uint32 s_gasLimit;
        uint64 s_subscriptionId;
        bytes32 s_donID;
        bytes32 s_lastRequestId;
        bytes s_lastResponse;
        bytes s_lastError;
        string s_source;
        address s_router;
        mapping(bytes32 _requestId => FunctionResponse) s_functionResponse;
        mapping(uint256 => uint256) s_loanPrincipal;
        mapping(uint256 => uint256) s_loanStartTime;
        mapping(address => uint32) s_priceFeedStalenessThreshold; // token address -> max age in seconds (0 = use default)
        uint256 s_reentrancyStatus; // 1 = not entered, 2 = entered (0 defaults to 1)
        // Pooled outstanding principal per (position, token). Tracked separately
        // from s_positionBorrowed (which capitalizes interest) so the borrow
        // tally is decremented by principal only on repay. Appended at the end of
        // the struct for upgrade-safe storage layout.
        mapping(uint256 => mapping(address => uint256)) s_positionPrincipal;
        // Dedicated keeper allowlist for triggering protocol-funded Chainlink
        // Functions refreshes. Kept separate from `isWhitelisted` (the general
        // borrower/depositor onboarding gate) so ordinary users can never bill
        // the protocol's LINK subscription. Appended at the end of the struct
        // for upgrade-safe storage layout.
        mapping(address => bool) s_isKeeper;
        // Two-step (pull) position transfer: positionId -> proposed new owner.
        // A user-initiated `transferPositionOwnership` only records the proposal
        // here; the recipient must `acceptPositionTransfer` before ownership (and
        // the attached debt/collateral) moves, so no one can be forced to receive
        // an unwanted position. Appended at the end for upgrade-safe layout.
        mapping(uint256 => address) s_pendingPositionTransfer;
        // Aggregate collateral held per token across all positions. Maintained
        // alongside every `s_positionCollateral` mutation so a collateral token
        // can only be delisted once no position still holds it — otherwise
        // removal drops the token from `s_allCollateralTokens`, silently valuing
        // outstanding holdings at zero and making solvent positions liquidatable.
        // Appended at the end for upgrade-safe layout.
        mapping(address => uint256) s_totalCollateralDeposited;
        // Per-collateral liquidation threshold in basis points, separate from the
        // per-token LTV (which is the origination/borrow limit). A position is
        // liquidatable once its debt exceeds Σ(collateralValue · threshold). A zero
        // entry means "use the protocol default" (`Constants.LIQUIDATION_THRESHOLD`,
        // 90%), so existing collaterals and the default deployment keep exactly the
        // current flat-90%-of-raw behaviour until governance tunes a token.
        // Appended at the end for upgrade-safe layout.
        mapping(address => uint16) s_collateralLiquidationThreshold;
        // Delegated whitelister allowlist. An address here may add users to the
        // `isWhitelisted` onboarding set (e.g. an automated KYC/onboarding backend)
        // WITHOUT holding the full security-council key. Blacklisting stays
        // council-only by design: a blacklist freezes deposits, borrows, collateral,
        // yield claims, AND vault withdrawals, so its blast radius is kept off any
        // automated hot key. Kept separate from `s_isKeeper` (the price-refresh
        // capability) and additive to the council. Appended at the end for
        // upgrade-safe layout.
        mapping(address => bool) s_isWhitelister;
        // Delegated guardian allowlist. A guardian may PAUSE markets / vaults / yield
        // (emergency fail-safe — the lowest-blast-radius admin action, and exits stay
        // open) WITHOUT holding the council key, so an automated monitor can freeze a
        // misbehaving market fast. UNPAUSE / resume is deliberately NOT delegated
        // (stays council-only), the classic asymmetric pause pattern — a compromised
        // guardian can grief but can never turn protection back off. Appended at the
        // end for upgrade-safe layout.
        mapping(address => bool) s_isGuardian;
    }

    bytes32 internal constant STORAGE_SLOT = keccak256("contracts.storage.LibAppStorage");

    /// @notice Returns a storage pointer to the protocol's shared `StorageLayout` at a fixed diamond storage slot.
    /// @return ds The storage reference to the protocol's application storage.
    function appStorage() internal pure returns (StorageLayout storage ds) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            ds.slot := slot
        }
    }
}
