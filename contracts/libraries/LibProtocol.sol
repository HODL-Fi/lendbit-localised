// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibInterestRateModel} from "./LibInterestRateModel.sol";
import {LibPositionManager} from "./LibPositionManager.sol";
import {LibPriceOracle} from "./LibPriceOracle.sol";
import {LibVaultManager} from "./LibVaultManager.sol";
import {LibYieldStrategy} from "./LibYieldStrategy.sol";

import {Constants} from "../models/Constant.sol";
import "../models/Error.sol";
import "../models/Event.sol";
import "../models/Protocol.sol";
import {RepayStateChangeParams} from "../models/FunctionParams.sol";

import {TokenVault} from "../TokenVault.sol";

library LibProtocol {
    using LibPositionManager for LibAppStorage.StorageLayout;
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using LibVaultManager for LibAppStorage.StorageLayout;

    function _depositCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        _validateAmount(_token, _amount);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);

        if (_positionId == 0) {
            _positionId = s._createPositionFor(msg.sender);
        }
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        _allowanceAndBalanceCheck(_token, _amount);

        s.s_positionCollateral[_positionId][_token] += _amount;

        if (_token != Constants.NATIVE_TOKEN) {
            bool _success = ERC20(_token).transferFrom(msg.sender, address(this), _amount);
            if (!_success) revert TRANSFER_FAILED();
        }

        LibYieldStrategy._rebalancePosition(s, _positionId, _token);
        emit CollateralDeposited(_positionId, _token, _amount);
    }

    function _withdrawCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        uint256 _positionId = _positionIdCheck(s);
        if (s.s_positionCollateral[_positionId][_token] < _amount) revert INSUFFICIENT_BALANCE();

        s.s_positionCollateral[_positionId][_token] -= _amount;
        uint256 _healthFactor = _getHealthFactor(s, _positionId, 0);

        uint256 _debtValue = _getPositionBorrowedValue(s, _positionId) + _totalActiveDebt(s, _positionId);
        if (_debtValue > 0) {
            if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);
        }

        LibYieldStrategy._rebalancePosition(s, _positionId, _token);
        LibYieldStrategy._ensureSufficientIdle(s, _positionId, _token, _amount);

        _transferToken(_token, msg.sender, _amount);
        emit CollateralWithdrawn(_positionId, _token, _amount);
    }

    function _takeLoan(
        LibAppStorage.StorageLayout storage s,
        address _token,
        uint256 _principal,
        uint256 _tenureSeconds
    ) internal returns (uint256) {
        uint256 _positionId = _positionIdCheck(s);
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);

        (, uint256 _currentBorrowValue) = s._getTokenValueInUSD(_token, _principal);
        uint256 _healthFactor = _getHealthFactor(s, _positionId, _currentBorrowValue);
        if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);

        Loan memory _loan = Loan({
            positionId: _positionId,
            token: _token,
            principal: _principal,
            repaid: 0,
            outstanding: _principal,
            tenureSeconds: _tenureSeconds,
            startTimestamp: block.timestamp,
            annualRateBps: s.s_interestRate,
            penaltyRateBps: s.s_penaltyRate,
            status: LoanStatus.FULFILLED
        });

        uint256 _loanId = ++s.s_nextLoanId;
        s.s_loans[_loanId] = _loan;
        s.s_positionActiveLoanIds[_positionId].push(_loanId);

        s._updateVaultBorrows(_loan.token, _loan.principal);

        TokenVault _vault = s.i_tokenVault[_loan.token];
        _vault.borrow(msg.sender, _loan.principal);

        emit LoanTaken(_positionId, _loanId, _loan.token, _loan.principal, _loan.tenureSeconds, _loan.annualRateBps);
        return _loanId;
    }

    function _repayLoanFor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _loanId, uint256 _amount)
        internal
        returns (uint256)
    {
        Loan storage _loan = s.s_loans[_loanId];
        if (_loan.positionId != _positionId) revert NOT_LOAN_OWNER(_positionId);
        if (_loan.status != LoanStatus.FULFILLED) revert INACTIVE_LOAN();

        uint256 _loanDebt = _outstandingBalance(_loan, block.timestamp);
        if (_loanDebt == 0) revert NO_OUTSTANDING_DEBT(_positionId, _loan.token);

        _allowanceAndBalanceCheck(_loan.token, _amount);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        // Update loan repaid amount
        _loan.repaid += _amount;
        _loan.outstanding = _loanDebt - _amount;

        // If fully repaid, update loan status and move to closed loans
        if (_loanDebt - _amount == 0) {
            _loan.status = LoanStatus.REPAID;
            _removeLoanFromActive(s, _positionId, _loanId);
            s.s_positionClosedLoanIds[_positionId].push(_loanId);
        }

        s._updateVaultRepays(_loan.token, _amount);

        bool _success = ERC20(_loan.token).transferFrom(msg.sender, address(s.i_tokenVault[_loan.token]), _amount);
        if (!_success) revert TRANSFER_FAILED();

        emit LoanRepayment(_positionId, _loanId, _loan.token, _amount);
        return _loanDebt - _amount;
    }

    function _repayLoan(LibAppStorage.StorageLayout storage s, uint256 _loanId, uint256 _amount)
        internal
        returns (uint256)
    {
        uint256 _positionId = _positionIdCheck(s);
        return _repayLoanFor(s, _positionId, _loanId, _amount);
    }

    function _borrow(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount)
        internal
        returns (uint256)
    {
        uint256 _positionId = _positionIdCheck(s);
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        if (!s._validateVaultUtlization(_token, _amount)) revert TOKEN_OVERUTILIZATION();

        (, uint256 _currentBorrowValue) = s._getTokenValueInUSD(_token, _amount);
        uint256 _healthFactor = _getHealthFactor(s, _positionId, _currentBorrowValue);

        if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);

        uint256 _tokenBorrow = s.s_positionBorrowed[_positionId][_token];
        if (_tokenBorrow == 0) {
            s.s_positionBorrowed[_positionId][_token] += _amount;
        } else {
            s.s_positionBorrowed[_positionId][_token] = _calculateUserDebt(s, _positionId, _token, _amount);
        }

        s.s_positionBorrowedLastUpdate[_positionId][_token] = block.timestamp;

        s._updateVaultBorrows(_token, _amount);

        TokenVault _vault = s.i_tokenVault[_token];
        _vault.borrow(msg.sender, _amount);

        emit BorrowComplete(_positionId, _token, _amount);
        return s.s_positionBorrowed[_positionId][_token];
    }

    function _repay(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal returns (uint256) {
        uint256 _positionId = _positionIdCheck(s);

        uint256 _debt = s.s_positionBorrowed[_positionId][_token];
        if (_debt == 0) revert NO_OUTSTANDING_DEBT(_positionId, _token);

        _allowanceAndBalanceCheck(_token, _amount);

        if (_amount > _debt) {
            _amount = _debt;
        }

        RepayStateChangeParams memory _params =
            RepayStateChangeParams({positionId: _positionId, token: _token, amount: _amount});
        _repayStateChanges(s, _params);
        s._updateVaultRepays(address(_token), _amount);

        bool _success = ERC20(_token).transferFrom(msg.sender, address(s.i_tokenVault[_token]), _amount);
        if (!_success) revert TRANSFER_FAILED();

        emit Repay(_positionId, _token, _amount);
        return _calculateUserDebt(s, _positionId, _token, 0);
    }

    function _repayStateChanges(LibAppStorage.StorageLayout storage s, RepayStateChangeParams memory _params) internal {
        uint256 _totalDebt = _calculateUserDebt(s, _params.positionId, _params.token, 0);
        s.s_positionBorrowed[_params.positionId][_params.token] = _totalDebt - _params.amount;
        s.s_positionBorrowedLastUpdate[_params.positionId][_params.token] = block.timestamp;
        s._updateVaultRepays(_params.token, _params.amount);
    }

    function _allowanceAndBalanceCheck(address _token, uint256 _amount) internal view {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();
        if (_token != Constants.NATIVE_TOKEN) {
            if (ERC20(_token).allowance(msg.sender, address(this)) < _amount) revert INSUFFICIENT_ALLOWANCE();
            if (ERC20(_token).balanceOf(msg.sender) < _amount) revert INSUFFICIENT_BALANCE();
        } else {
            if (msg.value < _amount) revert AMOUNT_MISMATCH(msg.value, _amount);
        }
    }

    function _positionIdCheck(LibAppStorage.StorageLayout storage s) internal view returns (uint256) {
        _callerWhitelisted(s);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);
        if (_positionId == 0) revert NO_POSITION_ID(msg.sender);
        return _positionId;
    }

    function _callerWhitelisted(LibAppStorage.StorageLayout storage s) internal view {
        if (!s.isWhitelisted[msg.sender]) revert ADDRESS_NOT_WHITELISTED(msg.sender);
    }

    function _addCollateralToken(
        LibAppStorage.StorageLayout storage s,
        address _token,
        address _pricefeed,
        uint16 _tokenLTV
    ) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_pricefeed == address(0)) revert ADDRESS_ZERO();
        if (_tokenLTV < 1000) revert LTV_BELOW_TEN_PERCENT();
        if (s.s_supportedCollateralTokens[_token]) revert TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL(_token);

        s.s_supportedCollateralTokens[_token] = true;
        s.s_allCollateralTokens.push(_token);
        s.s_tokenPriceFeed[_token] = _pricefeed;
        s.s_collateralTokenLTV[_token] = _tokenLTV;

        emit CollateralTokenAdded(_token);
        emit CollateralTokenLTVUpdated(_token, 0, _tokenLTV);
    }

    function _removeCollateralToken(LibAppStorage.StorageLayout storage s, address _token) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED_AS_COLLATERAL(_token);

        s.s_supportedCollateralTokens[_token] = false;
        // delete s.s_tokenPriceFeed[_token];

        // remove from array
        uint256 length = s.s_allCollateralTokens.length;
        for (uint256 i = 0; i < length; i++) {
            if (s.s_allCollateralTokens[i] == _token) {
                s.s_allCollateralTokens[i] = s.s_allCollateralTokens[length - 1];
                s.s_allCollateralTokens.pop();
                break;
            }
        }

        emit CollateralTokenRemoved(_token);
    }

    function _setInterestRate(LibAppStorage.StorageLayout storage s, uint16 _newInterestRate, uint16 _newPenaltyRate)
        internal
    {
        if (_newInterestRate == 0) revert AMOUNT_ZERO();
        if (_newPenaltyRate == 0) revert AMOUNT_ZERO();
        s.s_interestRate = _newInterestRate;
        s.s_penaltyRate = _newPenaltyRate;
        emit InterestRateUpdated(_newInterestRate, _newPenaltyRate);
    }

    function _setCollateralTokenLtv(LibAppStorage.StorageLayout storage s, address _token, uint16 _tokenNewLTV)
        internal
    {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_tokenNewLTV < 1000) revert LTV_BELOW_TEN_PERCENT();
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED_AS_COLLATERAL(_token);

        uint16 _oldLTV = s.s_collateralTokenLTV[_token];
        s.s_collateralTokenLTV[_token] = _tokenNewLTV;

        emit CollateralTokenLTVUpdated(_token, _oldLTV, _tokenNewLTV);
    }

    /*
     * @notice Removes a loan ID from the active loans list of a position
     * @param _positionId The user position id
     * @param _loanId The ID of the loan to remove
     */
    function _removeLoanFromActive(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _loanId)
        internal
    {
        uint256[] storage list = s.s_positionActiveLoanIds[_positionId];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == _loanId) {
                list[i] = list[list.length - 1];
                list.pop();
                return;
            }
        }
    }

    function _getPositionCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = 0;
        address[] memory _tokens = s.s_allCollateralTokens;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _token = _tokens[i];
            uint256 _usdValue = _getPositionCollateralTokenValue(s, _positionId, _token);
            _totalValue += _usdValue;
        }
        return _totalValue;
    }

    function _getPositionBorrowableCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = _getPositionUtilizableCollateralValue(s, _positionId);
        uint256 remainingCollateral =
            _totalValue - _getPositionBorrowedValue(s, _positionId) - _totalActiveDebt(s, _positionId);
        return remainingCollateral;
    }

    function _getPositionUtilizableCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = 0;
        address[] memory _tokens = s.s_allCollateralTokens;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _token = _tokens[i];
            uint16 _ltv = s.s_collateralTokenLTV[_token];
            uint256 _usdValue = _getPositionCollateralTokenValue(s, _positionId, _token);
            _totalValue += (_usdValue * _ltv) / Constants.BASIS_POINTS_SCALE;
        }
        return _totalValue;
    }

    function _getPositionCollateralTokenValue(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        address _token
    ) internal view returns (uint256) {
        uint256 _amount = s.s_positionCollateral[_positionId][_token];
        (, uint256 _usdValue) = s._getTokenValueInUSD(_token, _amount);
        return _usdValue;
    }

    function _getPositionBorrowedValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = 0;
        address[] memory _tokens = s.s_allSupportedTokens;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _token = _tokens[i];
            uint256 _amount = _calculateUserDebt(s, _positionId, _token, 0);
            (, uint256 _usdValue) = s._getTokenValueInUSD(_token, _amount);
            _totalValue += _usdValue;
        }
        return _totalValue;
    }

    // function _getHealthFactor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _currentBorrowValue)
    //     internal
    //     view
    //     returns (uint256)
    // {
    //     uint256 _collateralValue = _getPositionUtilizableCollateralValue(s, _positionId);
    //     uint256 _borrowedValue = _getPositionBorrowedValue(s, _positionId);

    //     _borrowedValue += _currentBorrowValue;

    //     if (_borrowedValue == 0) return (_collateralValue * Constants.PRECISION); // No debt means max health factor

    //     return _collateralValue * Constants.PRECISION / _borrowedValue; // Health factor with 18 decimals
    // }

    function _getHealthFactor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _currentBorrowValue)
        internal
        view
        returns (uint256)
    {
        uint256 _collateralValue = _getPositionUtilizableCollateralValue(s, _positionId);
        uint256 _borrowedValue = _totalActiveDebt(s, _positionId) + _getPositionBorrowedValue(s, _positionId);

        _borrowedValue += _currentBorrowValue;

        if (_borrowedValue == 0) return (_collateralValue * Constants.PRECISION); // No debt means max health factor

        return (_collateralValue * Constants.PRECISION) / _borrowedValue; // Health factor with 18 decimals
    }

    /**
     * @notice Calculates the current debt for a specific user including accrued interest
     * @param _positionId The positionId of the user
     * @param _token The token the debt is debt is owed
     * @param _amount The current amount to be borrowed
     * @return debt The current debt amount including interest
     */
    function _calculateUserDebt(
        LibAppStorage.StorageLayout storage s,
        uint256 _positionId,
        address _token,
        uint256 _amount
    ) internal view returns (uint256 debt) {
        uint256 _tokenBorrows = s.s_positionBorrowed[_positionId][_token];

        VaultConfiguration memory _config = s.s_tokenVaultConfig[_token];
        uint256 _from = s.s_positionBorrowedLastUpdate[_positionId][_token];

        uint256 _timeElapsed = block.timestamp - _from;
        uint256 utilization = LibInterestRateModel.calculateUtilization(_config.totalBorrows, _config.totalDeposits);
        uint256 interestRate = LibInterestRateModel.calculateInterestRate(_config, utilization);
        uint256 factor = ((interestRate * _timeElapsed) * 1e18) / (10000 * 365 days);
        debt = _amount + _tokenBorrows + ((_tokenBorrows * factor) / 1e18);

        return debt;
    }

    function _totalActiveDebt(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalDebt = 0;

        uint256[] memory _ids = s.s_positionActiveLoanIds[_positionId];
        for (uint256 i = 0; i < _ids.length; i++) {
            Loan memory _loan = s.s_loans[_ids[i]];
            (, uint256 _debt) = s._getTokenValueInUSD(_loan.token, _outstandingBalance(_loan, block.timestamp));
            _totalDebt += _debt;
        }
        return _totalDebt;
    }

    function _outstandingBalance(Loan memory _loan, uint256 _timestamp) internal pure returns (uint256) {
        if (_loan.status != LoanStatus.FULFILLED) return 0;

        uint256 _timeElapsed = _timestamp - _loan.startTimestamp;
        if (_timeElapsed > _loan.tenureSeconds) {
            _timeElapsed = _loan.tenureSeconds;
        }

        uint256 _interest =
            (_loan.outstanding * _loan.annualRateBps * _timeElapsed) / (Constants.BASIS_POINTS_SCALE_256 * 365 days);
        uint256 _totalOwed = _loan.outstanding + _interest;

        if (_timestamp > (_loan.startTimestamp + _loan.tenureSeconds)) {
            uint256 penaltyTime = _timestamp - (_loan.startTimestamp + _loan.tenureSeconds);
            uint256 penalty = (_loan.outstanding * (_loan.annualRateBps + _loan.penaltyRateBps) * penaltyTime)
                / (Constants.BASIS_POINTS_SCALE_256 * 365 days);
            _totalOwed += penalty;
        }

        if (_totalOwed <= _loan.repaid) {
            return 0;
        }

        return _totalOwed;
    }

    function _outstandingBalance(LibAppStorage.StorageLayout storage s, uint256 _loanId, uint256 _timestamp)
        internal
        view
        returns (uint256)
    {
        Loan memory _loan = s.s_loans[_loanId];
        return _outstandingBalance(_loan, _timestamp);
    }

    function _transferToken(address _token, address _to, uint256 _amount) internal {
        if (_to == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();

        if (_token == Constants.NATIVE_TOKEN) {
            (bool sent,) = _to.call{value: _amount}("");
            if (!sent) revert TRANSFER_FAILED();
            return;
        } else {
            bool _success = ERC20(_token).transfer(_to, _amount);
            if (!_success) revert TRANSFER_FAILED();
        }
    }

    function _validateAmount(address _token, uint256 _amount) internal view {
        if (_amount == 0) revert AMOUNT_ZERO();
        if (_token == Constants.NATIVE_TOKEN) {
            if (msg.value != _amount) revert AMOUNT_MISMATCH(msg.value, _amount);
        }
    }

    function _getUserActiveLoanIds(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256[] memory)
    {
        return s.s_positionActiveLoanIds[_positionId];
    }

    function _getActiveLoanIds(LibAppStorage.StorageLayout storage s) internal view returns (uint256[] memory) {
        uint256 totalLoans = s.s_nextLoanId;
        uint256 count = 0;

        for (uint256 i = 1; i <= totalLoans; i++) {
            if (s.s_loans[i].status == LoanStatus.FULFILLED) {
                count++;
            }
        }

        uint256[] memory activeLoanIds = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 1; i <= totalLoans; i++) {
            if (s.s_loans[i].status == LoanStatus.FULFILLED) {
                activeLoanIds[index] = i;
                index++;
            }
        }

        return activeLoanIds;
    }

    function _getLoanDetails(LibAppStorage.StorageLayout storage s, uint256 _loanId)
        internal
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
        Loan memory loan = s.s_loans[_loanId];
        return (
            loan.positionId,
            loan.token,
            loan.principal,
            loan.repaid,
            loan.tenureSeconds,
            loan.startTimestamp,
            _outstandingBalance(loan, block.timestamp),
            loan.annualRateBps,
            loan.penaltyRateBps,
            uint8(loan.status)
        );
    }
}
