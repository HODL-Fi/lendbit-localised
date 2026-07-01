// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";
import {LibVaultManager} from "../libraries/LibVaultManager.sol";

/// @title GettersFacet — read-only views over collateral, debt, loan, and vault state
contract GettersFacet {
    using LibProtocol for LibAppStorage.StorageLayout;
    using LibVaultManager for LibAppStorage.StorageLayout;

    /**
     * @notice Check if a token is supported as collateral
     * @param _token The token address to check
     * @return bool True if token is supported as collateral
     */
    function isCollateralTokenSupported(address _token) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_supportedCollateralTokens[_token];
    }

    /**
     * @notice Get all supported collateral tokens
     * @return address[] Array of all supported collateral token addresses
     */
    function getAllCollateralTokens() external view returns (address[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_allCollateralTokens;
    }

    /**
     * @notice Get collateral balance for a position and token
     * @param _positionId The position ID
     * @param _token The collateral token address
     * @return uint256 The collateral amount
     */
    function getPositionCollateral(uint256 _positionId, address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_positionCollateral[_positionId][_token];
    }

    /// @notice Return the total USD value of all collateral tokens held by a position.
    /// @param _positionId The position ID
    /// @return The total collateral value in USD
    function getPositionCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionCollateralValue(_positionId);
    }

    /**
     * @notice Get borrowable collateral value for a position based on the LTV of each collateral token and total debt
     * @param _positionId The position ID
     * @return uint256 The borrowable collateral value in USD
     */
    function getPositionBorrowableCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionBorrowableCollateralValue(_positionId);
    }

    /// @notice Return a position's LTV-weighted collateral value in USD (each token's value scaled by its loan-to-value ratio).
    /// @param _positionId The position ID
    /// @return The LTV-weighted (utilizable) collateral value in USD
    function getPositionUtilizableCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionUtilizableCollateralValue(_positionId);
    }

    /// @notice Return the total USD value of a position's open-ended (non-tenured) borrows across all supported tokens, including accrued interest.
    /// @param _positionId The position ID
    /// @return The borrowed value in USD
    function getPositionBorrowedValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionBorrowedValue(_positionId);
    }

    /// @notice Compute a position's health factor (18-decimal ratio of utilizable collateral to total debt plus the supplied prospective borrow); returns the max value when there is no debt.
    /// @param _positionId The position ID
    /// @param _currentBorrowValue An additional prospective borrow value in USD to include in the debt
    /// @return The health factor scaled by 1e18
    function getHealthFactor(uint256 _positionId, uint256 _currentBorrowValue) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getHealthFactor(_positionId, _currentBorrowValue);
    }

    /// @notice Return a position's current open-ended debt for a token in token units, including accrued interest.
    /// @param _positionId The position ID
    /// @param _token The borrowed token
    /// @return The outstanding debt for the token, including interest
    function getBorrowDetails(uint256 _positionId, address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._calculateUserDebt(_positionId, _token, 0);
    }

    /// @notice Return the configured loan-to-value ratio for a collateral token.
    /// @param _token The collateral token
    /// @return The token's LTV in basis points
    function getCollateralTokenLTV(address _token) external view returns (uint16) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_collateralTokenLTV[_token];
    }

    /// @notice Return the protocol's current interest rate and penalty rate.
    /// @return The annual interest rate in basis points
    /// @return The penalty rate in basis points
    function getInterestRate() external view returns (uint16, uint16) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return (s.s_interestRate, s.s_penaltyRate);
    }

    /// @notice Get the total debt for active tenured loans for a position
    /// @dev This function calculates the total outstanding debt for all active loans associated with a given position ID.
    /// It iterates through each active loan, computes the outstanding balance using the `_outstandingBalance` function from the `LibProtocol` library,
    /// and sums them up to return the total debt.
    /// @param _positionId The ID of the position for which to calculate the total active debt
    /// @return uint256 The total outstanding debt for all active loans of the position
    function getTotalActiveDebt(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._totalActiveDebt(_positionId);
    }

    /// @notice Return the outstanding balance of a fixed-term loan at the current block timestamp, including interest and any post-maturity penalty.
    /// @param _loanId The loan ID
    /// @return The loan's outstanding balance in token units
    function getOutstandingDebtForLoan(uint256 _loanId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._outstandingBalance(_loanId, block.timestamp);
    }

    /// @notice Return the list of active fixed-term loan IDs for a position.
    /// @param _positionId The position ID
    /// @return The array of active loan IDs for the position
    function getUserActiveLoanIds(uint256 _positionId) external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getUserActiveLoanIds(_positionId);
    }

    /// @notice Return the IDs of every fulfilled (active) fixed-term loan across all positions, scanning all loans ever created.
    /// @return The array of all active loan IDs
    function getActiveLoanIds() external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getActiveLoanIds();
    }

    /// @notice Return the full details of a fixed-term loan, including its current outstanding debt at the present timestamp.
    /// @param _loanId The loan ID
    /// @return positionId The position that owns the loan
    /// @return token The borrowed token
    /// @return principal The loan's remaining principal (falls back to the recorded original principal when zero)
    /// @return repaid The cumulative amount repaid against the loan
    /// @return tenureSeconds The loan's tenure in seconds
    /// @return startTimestamp The loan's origination timestamp
    /// @return debt The loan's current outstanding balance including interest and penalty
    /// @return annualRateBps The loan's annual interest rate in basis points
    /// @return penaltyRateBps The loan's penalty rate in basis points
    /// @return status The loan's status as a uint8 enum value
    function getLoanDetails(uint256 _loanId)
        external
        view
        returns (
            uint256 positionId,
            address token,
            uint256 principal,
            uint256 repaid,
            uint256 tenureSeconds,
            uint256 startTimestamp,
            uint256 debt,
            uint16 annualRateBps,
            uint16 penaltyRateBps,
            uint8 status
        )
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getLoanDetails(_loanId);
    }

    // VaultManager functions
    /// @notice Return the total assets held by a token's vault; reverts if no vault exists for the asset.
    /// @param asset The token whose vault to query
    /// @return The vault's total assets
    function getVaultTotalAssets(address asset) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getVaultTotalAssets(asset);
    }

    /// @notice Return whether a token is currently supported for deposit and borrowing.
    /// @param _token The token to check
    /// @return True if the token is supported
    function tokenIsSupported(address _token) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._tokenIsSupported(_token);
    }

    /// @notice Return the vault contract address for a token (zero address if none deployed).
    /// @param _token The token to look up
    /// @return The token's vault address
    function getTokenVault(address _token) external view returns (address) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getTokenVault(_token);
    }
}
