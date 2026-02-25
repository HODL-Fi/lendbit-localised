// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFunctionsRouter} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsRouter.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";

import {TokenVault} from "../TokenVault.sol";

import "../models/Protocol.sol";
import "../models/Yield.sol";

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

        address s_requestSigner;
        mapping(address => mapping(uint256 => bool)) s_requestRepayNonceUsed;

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
    }

    bytes32 internal constant STORAGE_SLOT = keccak256("contracts.storage.LibAppStorage");

    function appStorage() internal pure returns (StorageLayout storage ds) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            ds.slot := slot
        }
    }
}
