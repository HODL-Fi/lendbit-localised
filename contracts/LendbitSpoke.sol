// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {LibAppStorage} from "./libraries/LibAppStorage.sol";
import {LibLendbitSpoke} from "./libraries/LibLendbitSpoke.sol";
import {LibPositionManager} from "./libraries/LibPositionManager.sol";
import {LibProtocol} from "./libraries/LibProtocol.sol";
import {LibPriceOracle} from "./libraries/LibPriceOracle.sol";
import {LibLiquidation} from "./libraries/LibLiquidation.sol";

import {ReceiverTemplate} from "./interfaces/ReceiverTemplate.sol";

import {Loan, RepayRequest, LiquidationRequest} from "./models/Protocol.sol";
import {ONLY_SECURITY_COUNCIL, UNKNOWN_ACTION} from "./models/Error.sol";

contract LendbitSpoke is ReceiverTemplate {
    bytes32 constant LIQUIDATE_HASH = keccak256(bytes("LIQUIDATE_LOAN"));
    constructor(address forwarderAddress) ReceiverTemplate(forwarderAddress) {}

    function createPositionFor(address _user) external returns (uint256) {
        return LibPositionManager._createPositionFor(LibAppStorage.appStorage(), _user);
    }

    function createPositionAndWhitelistAddress(address _addr) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibPositionManager._whitelistAddress(s, _addr);
        LibPositionManager._createPositionFor(s, _addr);
    }

    function depositCollateral(address _token, uint256 _amount) external payable {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibLendbitSpoke._depositCollateral(s, _token, _amount);
    }

    function withdrawCollateral(address _token, uint256 _amount) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibLendbitSpoke._withdrawCollateral(s, _token, _amount);
    }

    function takeLoan(address _token, uint256 _principal, uint256 _tenureSeconds) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibLendbitSpoke._takeLoan(s, _token, _principal, _tenureSeconds);
    }

    function repayLoan(RepayRequest calldata _request, bytes calldata _signature) external returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibLendbitSpoke._repayLoan(s, _request, _signature);
    }

    function liquidateLoan(LiquidationRequest calldata _request, bytes calldata _signature) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibLendbitSpoke._liquidateLoan(s, _request, _signature);
    }

    function addCollateralToken(address _token, address _pricefeed, uint16 _tokenLTV) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibProtocol._addCollateralToken(s, _token, _pricefeed, _tokenLTV);
    }

    function removeCollateralToken(address _token) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibProtocol._removeCollateralToken(s, _token);
    }

    function addSupportedToken(address _token, address _pricefeed) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibLendbitSpoke._addSupportedToken(s, _token, _pricefeed);
    }

    function whitelistAddress(address _addr) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibPositionManager._whitelistAddress(s, _addr);
    }

    function blacklistAddress(address _addr) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibPositionManager._blacklistAddress(s, _addr);
    }

    function setInterestRate(uint16 _newInterestRate, uint16 _newPenaltyRate) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibProtocol._setInterestRate(s, _newInterestRate, _newPenaltyRate);
    }

    function setCollateralTokenLtv(address _token, uint16 _tokenNewLTV) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        LibProtocol._setCollateralTokenLtv(s, _token, _tokenNewLTV);
    }

    function isCollateralTokenSupported(address _token) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_supportedCollateralTokens[_token];
    }

    function getAllCollateralTokens() external view returns (address[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_allCollateralTokens;
    }

    function getPositionCollateral(uint256 _positionId, address _token) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_positionCollateral[_positionId][_token];
    }

    function getPositionCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibProtocol._getPositionCollateralValue(s, _positionId);
    }

    function getPositionBorrowableCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibLendbitSpoke._getPositionBorrowableCollateralValue(s, _positionId);
    }

    function getPositionUtilizableCollateralValue(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibProtocol._getPositionUtilizableCollateralValue(s, _positionId);
    }

    function getHealthFactor(uint256 _positionId, uint256 _currentBorrowValue) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibLendbitSpoke._getHealthFactor(s, _positionId, _currentBorrowValue);
    }

    // function getBorrowDetails(uint256 _positionId, address _token) external view returns (uint256) {
    //     LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
    //     return LibProtocol._calculateUserDebt(s, _positionId, _token, 0);
    // }

    function getCollateralTokenLTV(address _token) external view returns (uint16) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_collateralTokenLTV[_token];
    }

    function getInterestRate() external view returns (uint16, uint16) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return (s.s_interestRate, s.s_penaltyRate);
    }

    function getTotalActiveDebt(uint256 _positionId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibProtocol._totalActiveDebt(s, _positionId);
    }

    function getOutstandingDebtForLoan(uint256 _loanId) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibProtocol._outstandingBalance(s, _loanId, block.timestamp);
    }

    function getUserActiveLoanIds(uint256 _positionId) external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibProtocol._getUserActiveLoanIds(s, _positionId);
    }

    function getActiveLoanIds() external view returns (uint256[] memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibProtocol._getActiveLoanIds(s);
    }

    function setRequestSigner(address _signer) external onlySecurityCouncil {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s.s_requestSigner = _signer;
    }

    function getRequestSigner() external view returns (address) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_requestSigner;
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
        return LibProtocol._getLoanDetails(s, _loanId);
    }

    function getPositionIdForUser(address _user) external view returns (uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibPositionManager._getPositionIdForUser(s, _user);
    }

    function getTokenValueInUSD(address _token, uint256 _amount)
        external
        view
        returns (uint256 valueUSD, uint256 decimals)
    {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibPriceOracle._getTokenValueInUSD(s, _token, _amount);
    }

    function isLiquidatable(uint256 _positionId) external view returns (bool) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return LibLiquidation._isLiquidatable(s, _positionId);
    }

    function _processReport(bytes calldata report) internal override {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();

        if (report.length > 0 && report[0] == 0x01) {

            (, uint256 _loanId, uint256 _amount, address _collateralToken) =
                abi.decode(report[1:], (string, uint256, uint256, address));

            LibLendbitSpoke._liquidateLoanFor(s, _loanId, _amount, _collateralToken);
        } else if (report.length > 0 && report[0] == 0x02) {
            LibLendbitSpoke._handleRepayCreation(report[1:]);
        } else {
            revert UNKNOWN_ACTION("Unknown report action");
        }
    }

    modifier onlySecurityCouncil() {
        _onlySecurityCouncil();
        _;
    }

    function _onlySecurityCouncil() internal view {
        if (msg.sender != owner()) revert ONLY_SECURITY_COUNCIL();
    }
}
