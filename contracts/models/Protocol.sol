// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

struct Loan {
    uint256 positionId;
    address token;
    uint256 principal; // amount borrowed
    uint256 repaid;
    uint256 outstanding; // principal + interest accrued - repaid
    uint256 startTimestamp;
    uint256 tenureSeconds;
    uint16 annualRateBps;
    uint16 penaltyRateBps;
    LoanStatus status;
}

struct BorrowRequest {
    string action;
    uint256 positionId;
    address token;
    uint256 amount;
    uint256 tenureSeconds;
    uint256 sourceChainId;
    uint256 targetChainId;
    uint256 nonce;
    address contractAddress;
    address wallet;
}


struct VaultConfiguration {
    uint16 reserveFactor; // in basis points
    uint16 optimalUtilization; // in basis points
    uint16 baseRate; // in basis points
    uint16 slopeRate; // in basis points
    uint16 liquidationBonus; // in basis points
    uint256 totalDeposits;
    uint256 totalBorrows;
    uint256 lastUpdated; // timestamp
}

enum LoanStatus {
    REJECTED,
    FULFILLED,
    REPAID,
    LIQUIDATED
}

struct FunctionResponse {
    bool exists;
    bytes32 requestId;
    bytes responses;
    bytes err;
    uint256 priceData;
}
