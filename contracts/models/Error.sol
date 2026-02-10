// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

error ADDRESS_ZERO();
error ADDRESS_EXISTS(address userAddress);
error NO_POSITION_ID(address userAddress);
error NO_ACCESS_TO_POSITION_ID(address caller);
error POSITION_ID_MISMATCH(uint256 expected, uint256 given);
error ONLY_SECURITY_COUNCIL();
error SUBSCRIPTION_ID_NOT_SET();

error TOKEN_NOT_SUPPORTED(address asset);
error TOKEN_ALREADY_SUPPORTED(address asset, address assetVault);
error TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL(address asset);
error TOKEN_NOT_SUPPORTED_AS_COLLATERAL(address asset);

error REQUEST_BORROW_SIGNER_NOT_SET();
error REQUEST_BORROW_INVALID_SIGNATURE(address recovered);
error REQUEST_BORROW_NONCE_USED(address wallet, uint256 nonce);
error REQUEST_BORROW_TARGET_CHAIN_MISMATCH(uint256 expected, uint256 provided);
error REQUEST_BORROW_CONTRACT_MISMATCH(address expected, address provided);

error AMOUNT_ZERO();
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

error LTV_BELOW_TEN_PERCENT();
error TOKEN_OVERUTILIZATION();
error NO_OUTSTANDING_DEBT(uint256 positionId, address token);
error INACTIVE_LOAN();

error EMPTY_STRING();
error CURRENCY_ALREADY_SUPPORTED(string currency);
error CURRENCY_NOT_SUPPORTED(string currency);

error STALE_PRICE_FEED(address priceFeed);
error INVALID_PRICE_FEED(address priceFeed);

error YIELD_ALLOCATION_TOO_HIGH(uint16 bps);
error YIELD_NOT_ENABLED(address token);
error YIELD_TOKEN_PAUSED(address token);
error YIELD_NOTHING_TO_CLAIM(uint256 positionId, address token);
error YIELD_LIQUIDITY_DEFICIT(address token, uint256 deficit);

// chainlink functions error
error OnlyRouterCanFulfill();
error UnexpectedRequestID(bytes32 requestId);
