// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Error — File-level custom errors shared across the protocol's facets and libraries
// Grouped by domain: position/access, token support, borrow requests, lending, yield, and Chainlink Functions.
error ADDRESS_ZERO();
error ADDRESS_EXISTS(address userAddress);
error NO_POSITION_ID(address userAddress);
error NO_ACCESS_TO_POSITION_ID(address caller);
error POSITION_ID_MISMATCH(uint256 expected, uint256 given);
error ONLY_SECURITY_COUNCIL();
error SUBSCRIPTION_ID_NOT_SET();

error TOKEN_NOT_SUPPORTED(address asset);
error TOKEN_ALREADY_SUPPORTED(address asset, address assetVault);
error VAULT_NOT_EMPTY(uint256 shares, uint256 totalBorrows);
error TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL(address asset);
error TOKEN_NOT_SUPPORTED_AS_COLLATERAL(address asset);

error REQUEST_BORROW_SIGNER_NOT_SET();
error REQUEST_BORROW_INVALID_SIGNATURE(address recovered);
error REQUEST_BORROW_NONCE_USED(address wallet, uint256 nonce);
error REQUEST_BORROW_TARGET_CHAIN_MISMATCH(uint256 expected, uint256 provided);
error REQUEST_BORROW_CONTRACT_MISMATCH(address expected, address provided);
error REQUEST_BORROW_EXPIRED(uint256 deadline, uint256 timestamp);

error AMOUNT_ZERO();
error BAD_RATE();
error AMOUNT_MISMATCH(uint256 given, uint256 expected);
error TRANSFER_FAILED();
error INSUFFICIENT_ALLOWANCE();
error INSUFFICIENT_BALANCE();
error INSUFFICIENT_COLLATERAL();
error HEALTH_FACTOR_TOO_LOW(uint256 healthFactor);
error NOT_LIQUIDATABLE();
error NO_ACTIVE_BORROW_FOR_TOKEN(uint256 positionId, address token);
error NO_COLLATERAL_FOR_TOKEN(uint256 positionId, address token);
error NOT_LOAN_OWNER(uint256 positionId);
error ADDRESS_NOT_WHITELISTED(address caller);
error NOT_KEEPER(address caller);
error TENURE_TOO_SHORT();
error TOO_MANY_ACTIVE_LOANS(uint256 positionId);
error NO_PENDING_TRANSFER(uint256 positionId);
error NOT_PENDING_RECIPIENT(address caller);
error COLLATERAL_STILL_IN_USE(address token);

error LTV_BELOW_TEN_PERCENT();
error LTV_ABOVE_LIQUIDATION_THRESHOLD(uint16 ltv, uint16 threshold);
error UNAUTHORIZED_POSITION_CREATION(address caller);
error TOKEN_OVERUTILIZATION();
error NO_OUTSTANDING_DEBT(uint256 positionId, address token);
error REPAYMENT_BELOW_INTEREST(uint256 amount, uint256 interestDue);
error INACTIVE_LOAN();

error EMPTY_STRING();
error CURRENCY_ALREADY_SUPPORTED(string currency);
error CURRENCY_NOT_SUPPORTED(string currency);

error STALE_PRICE_FEED(address priceFeed);
error INVALID_PRICE_FEED(address priceFeed);
error ZERO_PRICE_DATA();

error YIELD_ALLOCATION_TOO_HIGH(uint16 bps);
error YIELD_NOT_ENABLED(address token);
error YIELD_TOKEN_PAUSED(address token);
error YIELD_NOTHING_TO_CLAIM(uint256 positionId, address token);
error YIELD_LIQUIDITY_DEFICIT(address token, uint256 deficit);
error BAD_POOL_ADDRESS(address pool);
error POOL_TOKEN_MISMATCH(address pool, address token);

// chainlink functions error
error OnlyRouterCanFulfill();
error UnexpectedRequestID(bytes32 requestId);
