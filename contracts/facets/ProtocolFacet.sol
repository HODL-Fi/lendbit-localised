// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";

import "../models/Error.sol";
import {BorrowRequest} from "../models/Protocol.sol";

contract ProtocolFacet {
    using LibProtocol for LibAppStorage.StorageLayout;

    /**
     * @notice Deposit collateral tokens to a position
     * @param _token The collateral token address
     * @param _amount The amount to deposit
     */
    function depositCollateral(address _token, uint256 _amount) external payable {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._depositCollateral(_token, _amount);
    }

    /**
     * @notice Withdraw collateral tokens from a position
     * @param _token The collateral token address
     * @param _amount The amount to withdraw
     */
    function withdrawCollateral(address _token, uint256 _amount) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._withdrawCollateral(_token, _amount);
    }

    function borrow(address _token, uint256 _amount) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._borrow(_token, _amount);
    }

    function repay(address _token, uint256 _amount) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repay(_token, _amount);
    }

    function takeLoan(address _token, uint256 _principal, uint256 _tenureSeconds) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._takeLoan(_token, _principal, _tenureSeconds);
    }

    function requestBorrow(BorrowRequest memory params, bytes memory signature) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._requestBorrow(params, signature);
    }

    function repayLoanFor(uint256 positionId, uint256 loanId, uint256 _amount) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repayLoanFor(positionId, loanId, _amount);
    }

    function repayLoan(uint256 loanId, uint256 _amount) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repayLoan(loanId, _amount);
    }

    /**
     * @notice Add a token as accepted collateral (only security council)
     * @param _token The token address to add as collateral
     */
    function addCollateralToken(address _token, address _pricefeed, uint16 _tokenLTV) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._addCollateralToken(_token, _pricefeed, _tokenLTV);
    }

    /**
     * @notice Remove a token from accepted collateral (only security council)
     * @param _token The token address to remove from collateral
     */
    function removeCollateralToken(address _token) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._removeCollateralToken(_token);
    }

    function setInterestRate(uint16 _newInterestRate, uint16 _newPenaltyRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setInterestRate(_newInterestRate, _newPenaltyRate);
    }

    function setCollateralTokenLtv(address _token, uint16 _tokenNewLTV) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setCollateralTokenLtv(_token, _tokenNewLTV);
    }

    // Modifiers
    modifier onlySecurityCouncil() {
        _onlySecurityCouncil();
        _;
    }

    function _onlySecurityCouncil() internal view {
        if (msg.sender != LibDiamond.contractOwner()) revert ONLY_SECURITY_COUNCIL();
    }
}
