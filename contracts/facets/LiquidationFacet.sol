// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibLiquidation} from "../libraries/LibLiquidation.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

contract LiquidationFacet is SecurityBase {
    using LibLiquidation for LibAppStorage.StorageLayout;

    function isLiquidatable(uint256 _positionId) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._isLiquidatable(_positionId);
    }

    function liquidateLoan(uint256 _loanId, uint256 _amount, address _collateralToken) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._liquidateLoan(_loanId, _amount, _collateralToken);
    }

    function liquidatePosition(uint256 _positionId, uint256 _amount, address _token, address _collateralToken)
        external
        nonReentrant
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._liquidatePosition(_positionId, _amount, _token, _collateralToken);
    }
}
