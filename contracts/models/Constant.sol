// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Holds all the constant for our protocol
library Constants {
    uint16 constant LIQUIDATION_THRESHOLD = 9000;
    uint16 constant COLLATERALIZATION_RATIO = 8000;
    uint16 constant MAX_UTILIZATION = 8000;
    uint256 constant PRECISION = 1e18;
    uint256 constant PRICE_PRECISION = 1e10;
    uint256 constant MIN_HEALTH_FACTOR = 1e18;
    address constant NATIVE_TOKEN = address(1);

    // Constants to avoid magic numbers
    uint8 constant DEFAULT_COMPOUNDING_PERIODS = 12; // Monthly compounding
    uint8 constant PRECISION_SCALE = 18; // High precision for calculations
    uint16 constant BASIS_POINTS_SCALE = 1e4; // 100% = 10000 basis points
    uint256 constant BASIS_POINTS_SCALE_256 = 1e4; // 100% = 10000 basis points
    uint32 constant MAX_APR_BASIS_POINTS = 1e6; // Maximum 10000% APR
    uint256 constant ZERO = 0;

    // Chainlink price feed staleness — used as fallback when no per-feed threshold is set
    uint32 constant DEFAULT_STALENESS_THRESHOLD = 3600; // 1 hour
}
