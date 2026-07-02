// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";

import "../models/Error.sol";
import {BorrowRequest} from "../models/Protocol.sol";
import {SecurityBase} from "../libraries/SecurityBase.sol";

/// @title ProtocolFacet — borrowing, repayment, and collateral entry points for the lending diamond
contract ProtocolFacet is SecurityBase {
    using LibProtocol for LibAppStorage.StorageLayout;

    /**
     * @notice Deposit collateral tokens to a position
     * @param _token The collateral token address
     * @param _amount The amount to deposit
     */
    function depositCollateral(address _token, uint256 _amount) external payable nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._depositCollateral(_token, _amount);
    }

    /**
     * @notice Withdraw collateral tokens from a position
     * @param _token The collateral token address
     * @param _amount The amount to withdraw
     */
    function withdrawCollateral(address _token, uint256 _amount) external nonReentrant {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._withdrawCollateral(_token, _amount);
    }

    /// @notice Borrow a supported token against the caller's position, accruing interest at the fixed protocol rate; reverts if the resulting health factor is below the minimum or the vault is over-utilized.
    /// @param _token The token to borrow
    /// @param _amount The amount to borrow
    /// @return The caller's total outstanding debt for the token after borrowing
    function borrow(address _token, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._borrow(_token, _amount);
    }

    /// @notice Repay the caller's open-ended borrow for a token, applying the payment to debt and the principal portion to the vault; the amount is clamped to the outstanding debt.
    /// @param _token The borrowed token to repay
    /// @param _amount The amount to repay (clamped to the outstanding debt)
    /// @return The caller's remaining debt for the token after repayment
    function repay(address _token, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repay(_token, _amount);
    }

    /// @notice Open a fixed-term loan against the caller's position for a supported token; reverts if the tenure is below one day, the vault is over-utilized, or the health factor would drop below the minimum.
    /// @param _token The token to borrow
    /// @param _principal The loan principal
    /// @param _tenureSeconds The loan duration in seconds (minimum one day)
    /// @return The newly created loan ID
    function takeLoan(address _token, uint256 _principal, uint256 _tenureSeconds)
        external
        nonReentrant
        returns (uint256)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._takeLoan(_token, _principal, _tenureSeconds);
    }

    /// @notice Open a fixed-term loan on behalf of a wallet from a signed cross-chain borrow request, validating the signer, target chain, contract, deadline, and a single-use nonce before fulfilling.
    /// @param params The borrow request describing wallet, position, token, amount, tenure, chain IDs, nonce, and deadline
    /// @param signature The protocol signer's signature over the request
    /// @return The newly created loan ID
    function requestBorrow(BorrowRequest calldata params, bytes calldata signature)
        external
        nonReentrant
        returns (uint256)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._requestBorrow(params, signature);
    }

    /// @notice Repay a fixed-term loan owned by a given position, allocating interest and penalty before principal; the payment is clamped to the outstanding debt and must at least cover accrued interest.
    /// @param positionId The position that owns the loan
    /// @param loanId The loan to repay
    /// @param _amount The amount to repay (clamped to the outstanding debt)
    /// @return The loan's remaining principal after repayment
    function repayLoanFor(uint256 positionId, uint256 loanId, uint256 _amount) external nonReentrant returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._repayLoanFor(positionId, loanId, _amount);
    }

    /// @notice Repay one of the caller's own fixed-term loans, resolving the caller's position before applying the interest-first repayment.
    /// @param loanId The loan to repay
    /// @param _amount The amount to repay (clamped to the outstanding debt)
    /// @return The loan's remaining principal after repayment
    function repayLoan(uint256 loanId, uint256 _amount) external nonReentrant returns (uint256) {
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

    /// @notice Set the protocol's borrow interest rate and penalty rate, propagating the new interest rate to every deployed vault (only security council).
    /// @param _newInterestRate The new annual interest rate in basis points (non-zero)
    /// @param _newPenaltyRate The new penalty rate in basis points (non-zero)
    function setInterestRate(uint16 _newInterestRate, uint16 _newPenaltyRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setInterestRate(_newInterestRate, _newPenaltyRate);
    }

    /// @notice Update the loan-to-value ratio for an already-supported collateral token (only security council); reverts if the new LTV is below 10%.
    /// @param _token The collateral token to update
    /// @param _tokenNewLTV The new LTV in basis points (minimum 1000)
    function setCollateralTokenLtv(address _token, uint16 _tokenNewLTV) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setCollateralTokenLtv(_token, _tokenNewLTV);
    }

    /// @notice Set a collateral token's liquidation threshold (only security council).
    /// @dev Must be >= the token's LTV and <= 100% (10000 bps). Defaults to 90% at
    ///      onboarding, so leaving it unset preserves the flat-90% behaviour.
    /// @param _token The collateral token to configure
    /// @param _threshold The new liquidation threshold in basis points
    function setCollateralLiquidationThreshold(address _token, uint16 _threshold) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setCollateralLiquidationThreshold(_token, _threshold);
    }
}
