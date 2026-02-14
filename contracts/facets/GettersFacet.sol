// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";

contract GettersFacet {
    using LibProtocol for LibAppStorage.StorageLayout;

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

    function getPositionUtilizableCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionUtilizableCollateralValue(_positionId);
    }

    function getPositionBorrowedValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPositionBorrowedValue(_positionId);
    }

    function getHealthFactor(uint256 _positionId, uint256 _currentBorrowValue) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getHealthFactor(_positionId, _currentBorrowValue);
    }

    function getBorrowDetails(uint256 _positionId, address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._calculateUserDebt(_positionId, _token, 0);
    }

    function getCollateralTokenLTV(address _token) external view returns (uint16) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_collateralTokenLTV[_token];
    }

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

    function getOutstandingDebtForLoan(uint256 _loanId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._outstandingBalance(_loanId, block.timestamp);
    }

    function getUserActiveLoanIds(uint256 _positionId) external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getUserActiveLoanIds(_positionId);
    }

    function getActiveLoanIds() external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getActiveLoanIds();
    }

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
}
