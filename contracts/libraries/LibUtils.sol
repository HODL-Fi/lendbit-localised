// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Constants} from "../models/Constant.sol";

/// @title LibUtils — Token decimal normalization and USD/token amount conversion helpers
library LibUtils {
    /// @notice Normalizes a token amount to 18 decimals of precision
    /// @dev Converts token amounts to standard 18-decimal representation for consistent internal calculations
    /// @param _token The token address to get decimals from (NATIVE_TOKEN returns 18)
    /// @param _amount The amount to normalize in the token's native decimals
    /// @return The normalized amount in 18 decimals
    function _normalizeTokenAmount(address _token, uint256 _amount) internal view returns (uint256) {
        uint8 _decimals = LibUtils._getTokenDecimals(_token);
        return _noramlizeToNDecimals(_amount, _decimals, 18);
    }

    /// @notice Converts a value from one decimal precision to another
    /// @dev Handles both scaling up (multiplication) and scaling down (division) based on decimal difference
    /// @param _amount The raw amount to convert
    /// @param _amountDecimal The current decimal precision of the amount
    /// @param _newDecimal The target decimal precision
    /// @return The converted amount in the new decimal precision
    /// @dev Example: _noramlizeToNDecimals(1000, 6, 18) returns 1e15 (scales up by 1e12)
    function _noramlizeToNDecimals(uint256 _amount, uint8 _amountDecimal, uint8 _newDecimal)
        internal
        pure
        returns (uint256)
    {
        if (_amountDecimal <= _newDecimal) {
            return _amount * (10 ** (_newDecimal - _amountDecimal));
        } else {
            return _amount / (10 ** (_amountDecimal - _newDecimal));
        }
    }

    /// @notice Converts a USD amount to token amount using a price feed
    /// @dev Formula: (amountInUSD * 10^tokenDecimals) / normalizedPrice
    /// where normalizedPrice = _pricePerToken scaled from pricefeedDecimals to PRECISION_SCALE (18)
    /// @param _token The token address to determine decimal places
    /// @param _amountInUSD The amount in USD (assumed to be in 18-decimal precision)
    /// @param _pricePerToken The price per token from the price feed (in _pricefeedDecimals)
    /// @param _pricefeedDecimals The decimal places of the price feed (typically 8 for Chainlink feeds)
    /// @return The equivalent token amount in the token's native decimals
    /// @dev Note: Division order is (numerator) / (denominator). Subject to integer division precision loss.
    /// @dev Example: if price = 100e8 (Chainlink format), token decimals = 6, USD amount = 1e18
    ///     result = (1e18 * 1e6) / (100e8 * 1e10) = 1e24 / 1e18 = 1e6 tokens
    function _convertUSDToTokenAmount(
        address _token,
        uint256 _amountInUSD,
        uint256 _pricePerToken,
        uint8 _pricefeedDecimals
    ) internal view returns (uint256) {
        uint8 _decimals = _getTokenDecimals(_token);
        return (_amountInUSD * (10 ** _decimals))
            / LibUtils._noramlizeToNDecimals(_pricePerToken, _pricefeedDecimals, Constants.PRECISION_SCALE);
    }

    /// @notice Retrieves the decimal precision of a token
    /// @dev Special case: NATIVE_TOKEN (address(1)) always returns 18 decimals
    /// @param _token The token address (ERC20 contract or NATIVE_TOKEN)
    /// @return The decimal places of the token (0-18 typically)
    /// @dev Reverts if _token is neither NATIVE_TOKEN nor a valid ERC20 contract
    function _getTokenDecimals(address _token) internal view returns (uint8) {
        if (_token == Constants.NATIVE_TOKEN) return 18;
        return ERC20(_token).decimals();
    }
}
