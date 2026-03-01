// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibLiquidation} from "./LibLiquidation.sol";
import {LibProtocol, ERC20} from "./LibProtocol.sol";
import {LibPositionManager} from "./LibPositionManager.sol";
import {LibPriceOracle} from "./LibPriceOracle.sol";
import {Constants} from "../models/Constant.sol";

import {Loan, LoanStatus, LiquidationRequest, RepayRequest} from "../models/Protocol.sol";
import {
    TokenSupportChanged,
    CollateralDeposited,
    CollateralWithdrawn,
    LoanTaken,
    LoanLiquidated,
    LoanRepayment
} from "../models/Event.sol";

import {
    ADDRESS_NOT_WHITELISTED,
    ADDRESS_ZERO,
    INACTIVE_LOAN,
    INSUFFICIENT_BALANCE,
    INSUFFICIENT_COLLATERAL,
    HEALTH_FACTOR_TOO_LOW,
    LTV_BELOW_TEN_PERCENT,
    NOT_LOAN_OWNER,
    NO_OUTSTANDING_DEBT,
    REQUEST_SIGNER_NOT_SET,
    REQUEST_INVALID_SIGNATURE,
    REQUEST_REPAY_NONCE_USED,
    REQUEST_REPAY_TARGET_CHAIN_MISMATCH,
    REQUEST_REPAY_CONTRACT_MISMATCH,
    TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL,
    TOKEN_NOT_SUPPORTED,
    TOKEN_NOT_SUPPORTED_AS_COLLATERAL,
    TRANSFER_FAILED
} from "../models/Error.sol";

library LibLendbitSpoke {
    using LibLiquidation for LibAppStorage.StorageLayout;
    using LibPositionManager for LibAppStorage.StorageLayout;
    using LibPriceOracle for LibAppStorage.StorageLayout;

    function _depositCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        LibProtocol._validateAmount(_token, _amount);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);

        if (_positionId == 0) {
            _positionId = s._createPositionFor(msg.sender);
        }
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        LibProtocol._allowanceAndBalanceCheck(_token, _amount);

        s.s_positionCollateral[_positionId][_token] += _amount;

        if (_token != Constants.NATIVE_TOKEN) {
            bool _success = ERC20(_token).transferFrom(msg.sender, address(this), _amount);
            if (!_success) revert TRANSFER_FAILED();
        }

        emit CollateralDeposited(_positionId, _token, _amount);
    }

    function _withdrawCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        uint256 _positionId = LibProtocol._positionIdCheck(s);
        if (s.s_positionCollateral[_positionId][_token] < _amount) revert INSUFFICIENT_BALANCE();

        s.s_positionCollateral[_positionId][_token] -= _amount;
        uint256 _healthFactor = _getHealthFactor(s, _positionId, 0);

        uint256 _debtValue = LibProtocol._totalActiveDebt(s, _positionId);
        if (_debtValue > 0) {
            if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);
        }

        LibProtocol._transferToken(_token, msg.sender, _amount);
        emit CollateralWithdrawn(_positionId, _token, _amount);
    }

    function _takeLoan(
        LibAppStorage.StorageLayout storage s,
        address _token,
        uint256 _principal,
        uint256 _tenureSeconds
    ) internal returns (uint256) {
        uint256 _positionId = LibProtocol._positionIdCheck(s);
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);

        (, uint256 _currentBorrowValue) = s._getTokenValueInUSD(_token, _principal);
        uint256 _healthFactor = _getHealthFactor(s, _positionId, _currentBorrowValue);
        if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);

        Loan memory _loan = Loan({
            positionId: _positionId,
            token: _token,
            principal: _principal,
            repaid: 0,
            tenureSeconds: _tenureSeconds,
            startTimestamp: block.timestamp,
            annualRateBps: s.s_interestRate,
            penaltyRateBps: s.s_penaltyRate,
            status: LoanStatus.FULFILLED
        });

        uint256 _loanId = ++s.s_nextLoanId;
        s.s_loans[_loanId] = _loan;
        s.s_positionActiveLoanIds[_positionId].push(_loanId);
        s.s_loanPrincipal[_loanId] = _principal;
        s.s_loanStartTime[_loanId] = block.timestamp;

        emit LoanTaken(_positionId, _loanId, _loan.token, _loan.principal, _loan.tenureSeconds, _loan.annualRateBps);
        return _loanId;
    }

    function _liquidateLoan(
        LibAppStorage.StorageLayout storage s,
        LiquidationRequest calldata _request,
        bytes calldata _signature
    ) internal {
        _verifyLiquidationRequest(s, _request, _signature);

        _liquidateLoanFor(s, _request.loanId, _request.amount, _request.collateralToken);
    }

    function _liquidateLoanFor(
        LibAppStorage.StorageLayout storage s,
        uint256 _loanId,
        uint256 _amount,
        address _collateralToken
    ) internal {
        Loan storage _loan = s.s_loans[_loanId];
        if (_loan.status != LoanStatus.FULFILLED) revert INACTIVE_LOAN();
        s._liquidationCheck(_loan.positionId, _loan.token, _collateralToken, _amount);

        uint256 _amountToLiquidate = LibLiquidation._getAmountToLiquidate(s, _collateralToken, _loan.token, _amount);
        if (_amountToLiquidate > s.s_positionCollateral[_loan.positionId][_collateralToken]) {
            revert INSUFFICIENT_COLLATERAL();
        }
        s.s_positionCollateral[_loan.positionId][_collateralToken] -= _amountToLiquidate;

        // Update loan repaid amount
        uint256 _loanDebt = LibProtocol._outstandingBalance(s, _loanId, block.timestamp);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        // update outstanding loan here
        _loan.repaid += _amount;
        _loan.principal = _loanDebt - _amount;
        _loan.startTimestamp = block.timestamp;

        // If fully repaid, update loan status and move to closed loans
        if (_loan.principal == 0) {
            _loan.status = LoanStatus.LIQUIDATED;
            LibProtocol._removeLoanFromActive(s, _loan.positionId, _loanId);
            s.s_positionClosedLoanIds[_loan.positionId].push(_loanId);
        }

        LibProtocol._transferToken(_collateralToken, msg.sender, _amountToLiquidate);

        emit LoanLiquidated(_loan.positionId, _loanId, _collateralToken, msg.sender, _amountToLiquidate);
        emit LoanRepayment(_loan.positionId, _loanId, _loan.token, _amount);
    }

    function _repayLoanFor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _loanId, uint256 _amount)
        internal
        returns (uint256)
    {
        Loan storage _loan = s.s_loans[_loanId];
        if (_loan.positionId != _positionId) revert NOT_LOAN_OWNER(_positionId);
        if (_loan.status != LoanStatus.FULFILLED) revert INACTIVE_LOAN();

        uint256 _loanDebt = LibProtocol._outstandingBalance(_loan, block.timestamp);
        if (_loanDebt == 0) revert NO_OUTSTANDING_DEBT(_positionId, _loan.token);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        // Update loan repaid amount
        _loan.repaid += _amount;
        _loan.principal = _loanDebt - _amount;
        _loan.startTimestamp = block.timestamp;

        // If fully repaid, update loan status and move to closed loans
        if (_loan.principal == 0) {
            _loan.status = LoanStatus.REPAID;
            LibProtocol._removeLoanFromActive(s, _positionId, _loanId);
            s.s_positionClosedLoanIds[_positionId].push(_loanId);
        }

        emit LoanRepayment(_positionId, _loanId, _loan.token, _amount);
        return _loan.principal;
    }

    function _repayLoan(
        LibAppStorage.StorageLayout storage s,
        RepayRequest calldata _request,
        bytes calldata _signature
    ) internal returns (uint256) {
        _verifyRepayRequest(s, _request, _signature);

        uint256 _positionId = LibProtocol._positionIdCheck(s);
        return _repayLoanFor(s, _positionId, _request.loanId, _request.amount);
    }

    function _verifyRepayRequest(
        LibAppStorage.StorageLayout storage s,
        RepayRequest calldata _request,
        bytes calldata _signature
    ) internal {
        if (s.s_requestSigner == address(0)) revert REQUEST_SIGNER_NOT_SET();

        bytes32 _hash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        _request.action,
                        _request.loanId,
                        _request.amount,
                        _request.sourceChainId,
                        _request.targetChainId,
                        _request.nonce,
                        _request.contractAddress
                    )
                )
            )
        );

        address _recovered =
            ecrecover(_hash, uint8(_signature[64]), bytes32(_signature[0:32]), bytes32(_signature[32:64]));
        if (_recovered != s.s_requestSigner) revert REQUEST_INVALID_SIGNATURE(_recovered);

        if (s.s_requestRepayNonceUsed[_recovered][_request.nonce]) {
            revert REQUEST_REPAY_NONCE_USED(_recovered, _request.nonce);
        }
        s.s_requestRepayNonceUsed[_recovered][_request.nonce] = true;

        if (_request.targetChainId != block.chainid) {
            revert REQUEST_REPAY_TARGET_CHAIN_MISMATCH(block.chainid, _request.targetChainId);
        }

        if (_request.contractAddress != address(this)) {
            revert REQUEST_REPAY_CONTRACT_MISMATCH(address(this), _request.contractAddress);
        }
    }

    function _verifyLiquidationRequest(
        LibAppStorage.StorageLayout storage s,
        LiquidationRequest calldata _request,
        bytes calldata _signature
    ) internal {
        if (s.s_requestSigner == address(0)) revert REQUEST_SIGNER_NOT_SET();

        bytes32 _hash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        _request.action,
                        _request.loanId,
                        _request.amount,
                        _request.sourceChainId,
                        _request.targetChainId,
                        _request.nonce,
                        _request.contractAddress,
                        _request.collateralToken
                    )
                )
            )
        );

        address _recovered =
            ecrecover(_hash, uint8(_signature[64]), bytes32(_signature[0:32]), bytes32(_signature[32:64]));
        if (_recovered != s.s_requestSigner) revert REQUEST_INVALID_SIGNATURE(_recovered);

        if (s.s_requestRepayNonceUsed[_recovered][_request.nonce]) {
            revert REQUEST_REPAY_NONCE_USED(_recovered, _request.nonce);
        }
        s.s_requestRepayNonceUsed[_recovered][_request.nonce] = true;

        if (_request.targetChainId != block.chainid) {
            revert REQUEST_REPAY_TARGET_CHAIN_MISMATCH(block.chainid, _request.targetChainId);
        }

        if (_request.contractAddress != address(this)) {
            revert REQUEST_REPAY_CONTRACT_MISMATCH(address(this), _request.contractAddress);
        }
    }

    function _addSupportedToken(LibAppStorage.StorageLayout storage s, address _token, address _pricefeed) internal {
        if ((_token == address(0)) || (_pricefeed == address(0))) {
            revert ADDRESS_ZERO();
        }

        s.s_allSupportedTokens.push(_token);
        s.s_supportedToken[_token] = true;
        s.s_tokenPriceFeed[_token] = _pricefeed;

        emit TokenSupportChanged(_token, true);
    }

    function _getHealthFactor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _currentBorrowValue)
        internal
        view
        returns (uint256)
    {
        uint256 _collateralValue = LibProtocol._getPositionUtilizableCollateralValue(s, _positionId);
        uint256 _borrowedValue = LibProtocol._totalActiveDebt(s, _positionId) + _currentBorrowValue;

        if (_borrowedValue == 0) return (_collateralValue * Constants.PRECISION); // No debt means max health factor

        return (_collateralValue * Constants.PRECISION) / _borrowedValue; // Health factor with 18 decimals
    }

    function _getPositionBorrowableCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = LibProtocol._getPositionUtilizableCollateralValue(s, _positionId);
        uint256 remainingCollateral = _totalValue - LibProtocol._totalActiveDebt(s, _positionId);
        return remainingCollateral;
    }
}
