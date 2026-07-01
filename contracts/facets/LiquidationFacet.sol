// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibLiquidation} from "../libraries/LibLiquidation.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title LiquidationFacet — liquidation of under-collateralized positions and fixed-term loans
contract LiquidationFacet is SecurityBase {
    using LibLiquidation for LibAppStorage.StorageLayout;

    /// @notice Return whether a position is eligible for liquidation, i.e. its debt exceeds the liquidation threshold applied to its collateral value.
    /// @param _positionId The position ID
    /// @return True if the position can be liquidated
    function isLiquidatable(uint256 _positionId) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._isLiquidatable(_positionId);
    }

    /// @notice Liquidate a fixed-term loan: the caller repays up to the loan's debt and seizes the equivalent collateral plus the liquidation bonus, requiring the owning position to be liquidatable.
    /// @param _loanId The loan to liquidate
    /// @param _amount The repayment amount (clamped to the loan's outstanding debt)
    /// @param _collateralToken The collateral token to seize from the position
    function liquidateLoan(uint256 _loanId, uint256 _amount, address _collateralToken) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._liquidateLoan(_loanId, _amount, _collateralToken);
    }

    /// @notice Liquidate a position's open-ended borrow for a token: the caller repays the borrow and seizes the equivalent collateral plus the liquidation bonus, requiring the position to be liquidatable and to have an active borrow for the token.
    /// @param _positionId The position to liquidate
    /// @param _amount The repayment amount
    /// @param _token The borrowed token being repaid
    /// @param _collateralToken The collateral token to seize from the position
    function liquidatePosition(uint256 _positionId, uint256 _amount, address _token, address _collateralToken)
        external
        nonReentrant
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._liquidatePosition(_positionId, _amount, _token, _collateralToken);
    }
}
