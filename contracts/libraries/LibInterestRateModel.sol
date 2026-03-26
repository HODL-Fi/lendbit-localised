// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "../models/Protocol.sol";

/**
 * @title LibInterestRateModel
 * @dev Library for calculating interest rates and utilization in a lending protocol
 */
library LibInterestRateModel {
    function calculateSimpleInterest(uint256 principal, uint256 rateBasisPoints, uint256 timeInSeconds)
        internal
        pure
        returns (uint256)
    {
        // Simple interest formula: Interest = Principal * Rate * Time
        // Rate is in basis points, so we divide by 10,000
        // Time is in seconds, so we divide by the number of seconds in a year (31,536,000)
        return (principal * rateBasisPoints * timeInSeconds) / (10000 * 365 days);
    }

    /**
     * @notice Calculates the interest rate based on utilization
     * @param _config The protocol pool configuration
     * @param utilization The current utilization rate (0-10000)
     * @return The interest rate in basis points (1-10000)
     */
    function calculateInterestRate(VaultConfiguration memory _config, uint256 utilization)
        internal
        pure
        returns (uint256)
    {
        if (utilization <= _config.optimalUtilization) {
            // Correct formula: baseRate + (slopeRate * utilization / optimalUtilization)
            return _config.baseRate + ((_config.slopeRate * utilization) / _config.optimalUtilization);
        } else {
            // For high utilization (above optimal):
            // baseRate + slopeRate + (slopeRate * 2 * excessUtilization / maxExcessUtilization)
            uint256 excessUtilization = utilization - _config.optimalUtilization;
            uint256 maxExcessUtilization = 10000 - _config.optimalUtilization;
            uint256 slopeComponent = (_config.slopeRate * 2 * excessUtilization) / maxExcessUtilization;

            return _config.baseRate + _config.slopeRate + slopeComponent;
        }
    }

    /**
     * @notice Calculates the current utilization rate
     * @param totalBorrows Total borrowed from the pool
     * @param poolLiquidity Total available liquidity
     * @return The utilization rate in basis points (1-10000)
     */
    function calculateUtilization(uint256 totalBorrows, uint256 poolLiquidity) internal pure returns (uint256) {
        if (poolLiquidity + totalBorrows == 0) return 0;

        return (totalBorrows * 10000) / (poolLiquidity + totalBorrows);
    }
}
