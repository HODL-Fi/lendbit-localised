// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
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

/// @title LibProtocol — core lending logic for collateral, borrowing, and repayment
library LibProtocol {
    using LibPositionManager for LibAppStorage.StorageLayout;
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using LibVaultManager for LibAppStorage.StorageLayout;

    using SafeERC20 for IERC20;

    /// @notice Deposit collateral for the caller's position, creating a position if
    ///         none exists, and rebalance it into the yield strategy.
    /// @dev Credits the amount ACTUALLY received via balance-diff (fee-on-transfer
    ///      safe); native token is taken via `msg.value`.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to deposit (or the native token sentinel).
    /// @param _amount Amount of collateral to deposit.
    function _depositCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        _validateAmount(_token, _amount);
        _callerWhitelisted(s);
        uint256 _positionId = s._getPositionIdForUser(msg.sender);

        if (_positionId == 0) {
            _positionId = s._createPositionFor(msg.sender);
        }
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        _allowanceAndBalanceCheck(_token, _amount);

        uint256 _creditedAmount = _amount;

        if (_token != Constants.NATIVE_TOKEN) {
            uint256 _before = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
            _creditedAmount = IERC20(_token).balanceOf(address(this)) - _before;
        }

        s.s_positionCollateral[_positionId][_token] += _creditedAmount;
        s.s_totalCollateralDeposited[_token] += _creditedAmount;

        LibYieldStrategy._rebalancePosition(s, _positionId, _token);
        emit CollateralDeposited(_positionId, _token, _creditedAmount);
    }

    /// @notice Withdraw collateral from the caller's position, reverting if it would
    ///         drop the position's health factor below the minimum while debt is open.
    /// @dev Rebalances out of the yield strategy before transferring the token out.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to withdraw.
    /// @param _amount Amount of collateral to withdraw.
    function _withdrawCollateral(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal {
        uint256 _positionId = _positionIdCheck(s);
        if (s.s_positionCollateral[_positionId][_token] < _amount) revert INSUFFICIENT_BALANCE();

        s.s_positionCollateral[_positionId][_token] -= _amount;
        s.s_totalCollateralDeposited[_token] -= _amount;
        uint256 _healthFactor = _getHealthFactor(s, _positionId, 0);

        uint256 _debtValue = _getPositionBorrowedValue(s, _positionId) + _totalActiveDebt(s, _positionId);
        if (_debtValue > 0) {
            if (_healthFactor < Constants.MIN_HEALTH_FACTOR) revert HEALTH_FACTOR_TOO_LOW(_healthFactor);
        }

        LibYieldStrategy._rebalanceForWithdrawal(s, _positionId, _token, _amount);

        _transferToken(_token, msg.sender, _amount);
        emit CollateralWithdrawn(_positionId, _token, _amount);
    }

    /// @notice Open a fixed-term loan against the caller's position and disburse the
    ///         principal from the token's vault to the caller.
    /// @dev Validates token support, minimum tenure, vault utilization, and the
    ///      post-borrow health factor; records the loan and bumps vault borrows.
    /// @param s The diamond storage layout.
    /// @param _token Token to borrow.
    /// @param _principal Principal amount to borrow.
    /// @param _tenureSeconds Loan tenure in seconds (must be at least one day).
    /// @return The new loan's id.
    function _takeLoan(
        LibAppStorage.StorageLayout storage s,
        address _token,
        uint256 _principal,
        uint256 _tenureSeconds
    ) internal returns (uint256) {
        uint256 _positionId = _positionIdCheck(s);
        if (_principal == 0) revert AMOUNT_ZERO();
        if (!s.s_supportedToken[_token]) revert TOKEN_NOT_SUPPORTED(_token);
        if (_tenureSeconds < Constants.ONE_DAY) revert TENURE_TOO_SHORT();
        // Bound tenure above so `_originationTime + tenureSeconds` (maturity, computed
        // in `_outstandingBalance`) cannot overflow uint256 and brick the loan's repay
        // path — permanently stranding the borrower's collateral with no recovery (#H-01).
        if (_tenureSeconds > type(uint256).max - block.timestamp) {
            revert TENURE_TOO_LONG(_tenureSeconds, type(uint256).max - block.timestamp);
        }
        if (!s._validateVaultUtlization(_token, _principal)) revert TOKEN_OVERUTILIZATION();

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

        if (s.s_positionActiveLoanIds[_positionId].length >= Constants.MAX_ACTIVE_LOANS_PER_POSITION) {
            revert TOO_MANY_ACTIVE_LOANS(_positionId);
        }

        uint256 _loanId = ++s.s_nextLoanId;
        s.s_loans[_loanId] = _loan;
        s.s_positionActiveLoanIds[_positionId].push(_loanId);
        s.s_loanPrincipal[_loanId] = _principal;
        s.s_loanStartTime[_loanId] = block.timestamp;

        s._updateVaultBorrows(_loan.token, _loan.principal);

        TokenVault _vault = s.i_tokenVault[_loan.token];
        _vault.borrowFixed(msg.sender, _loan.principal, _loan.annualRateBps);

        emit LoanTaken(_positionId, _loanId, _loan.token, _loan.principal, _loan.tenureSeconds, _loan.annualRateBps);
        return _loanId;
    }

    /// @notice Open a fixed-term loan on behalf of a wallet from a signed,
    ///         cross-chain-attested borrow request, disbursing principal to that wallet.
    /// @dev Validates request fields, target chain/contract, optional deadline,
    ///      utilization, the off-chain signer's signature, and single-use nonce
    ///      before recording the loan.
    /// @param s The diamond storage layout.
    /// @param _request The borrow request (position, token, amount, tenure, chain, nonce, deadline, wallet).
    /// @param _signature The signer's signature over the request fields.
    /// @return The new loan's id.
    function _requestBorrow(
        LibAppStorage.StorageLayout storage s,
        BorrowRequest calldata _request,
        bytes calldata _signature
    ) internal returns (uint256) {
        if (bytes(_request.action).length == 0) revert EMPTY_STRING();
        if (_request.wallet == address(0) || _request.contractAddress == address(0)) revert ADDRESS_ZERO();
        if (_request.amount == 0) revert AMOUNT_ZERO();
        if (!s.s_supportedToken[_request.token]) revert TOKEN_NOT_SUPPORTED(_request.token);

        uint256 _storedPositionId = s._getPositionIdForUser(_request.wallet);
        if (_storedPositionId == 0) revert NO_POSITION_ID(_request.wallet);

        if (_storedPositionId != _request.positionId) {
            revert POSITION_ID_MISMATCH(_storedPositionId, _request.positionId);
        }

        // Honour an on-chain blacklist even for a pre-signed request: a wallet
        // removed from the whitelist after its request was signed can no longer
        // draw vault funds (defence-in-depth, mirrors the local borrow path's
        // `_callerWhitelisted`). See finding #6.
        if (!s.isWhitelisted[_request.wallet]) revert ADDRESS_NOT_WHITELISTED(_request.wallet);

        if (_request.targetChainId != block.chainid) {
            revert REQUEST_BORROW_TARGET_CHAIN_MISMATCH(block.chainid, _request.targetChainId);
        }
        if (_request.contractAddress != address(this)) {
            revert REQUEST_BORROW_CONTRACT_MISMATCH(address(this), _request.contractAddress);
        }

        // Optional signature expiry: a zero deadline means no expiry; a non-zero
        // deadline bounds how long a spoke-chain-attested request stays valid on the hub.
        if (_request.deadline != 0 && block.timestamp > _request.deadline) {
            revert REQUEST_BORROW_EXPIRED(_request.deadline, block.timestamp);
        }

        // Enforce the same minimum tenure as `_takeLoan`. (No hub-side health check
        // here by design: cross-chain borrows are backed by spoke-chain collateral
        // attested by the trusted signer, so the hub holds no collateral to measure
        // — a hub health check would revert every legitimate request. See
        // KNOWN_ISSUES.md §2.)
        if (_request.tenureSeconds < Constants.ONE_DAY) revert TENURE_TOO_SHORT();
        // Same maturity-overflow bound as `_takeLoan` (#H-01): a request-borrow loan
        // reaches the identical `_outstandingBalance` maturity computation.
        if (_request.tenureSeconds > type(uint256).max - block.timestamp) {
            revert TENURE_TOO_LONG(_request.tenureSeconds, type(uint256).max - block.timestamp);
        }

        if (!s._validateVaultUtlization(_request.token, _request.amount)) revert TOKEN_OVERUTILIZATION();

        _verifyBorrowSignature(s, _request, _signature);

        // Key replay protection by the borrowing WALLET, not `contractAddress`
        // (which is pinned to `address(this)` and so is a single global namespace).
        // A global namespace couples unrelated wallets: if the signer issues
        // wallet-local nonces, one wallet consuming nonce N blocks every other
        // wallet's legitimate nonce-N request (#7). Per-wallet keying makes each
        // wallet's nonce sequence independent while still preventing replay of the
        // same (wallet, nonce) — the signature binds the wallet, so this cannot be
        // spoofed.
        if (s.s_requestBorrowNonceUsed[_request.wallet][_request.nonce]) {
            revert REQUEST_BORROW_NONCE_USED(_request.wallet, _request.nonce);
        }
        s.s_requestBorrowNonceUsed[_request.wallet][_request.nonce] = true;

        Loan memory _loan = Loan({
            positionId: _request.positionId,
            token: _request.token,
            principal: _request.amount,
            repaid: 0,
            tenureSeconds: _request.tenureSeconds,
            startTimestamp: block.timestamp,
            annualRateBps: s.s_interestRate,
            penaltyRateBps: s.s_penaltyRate,
            status: LoanStatus.FULFILLED
        });

        if (s.s_positionActiveLoanIds[_request.positionId].length >= Constants.MAX_ACTIVE_LOANS_PER_POSITION) {
            revert TOO_MANY_ACTIVE_LOANS(_request.positionId);
        }

        uint256 _loanId = ++s.s_nextLoanId;
        s.s_loans[_loanId] = _loan;
        s.s_positionActiveLoanIds[_request.positionId].push(_loanId);
        // Record the immutable principal + origination timestamp, mirroring
        // `_takeLoan`. Without these, `s_loanStartTime[_loanId] == 0` and
        // `_outstandingBalance` falls back to the resettable `_loan.startTimestamp`,
        // so a partial repayment could move maturity / the penalty clock for a
        // request-borrow loan — the #6 fix would not cover this path.
        s.s_loanPrincipal[_loanId] = _request.amount;
        s.s_loanStartTime[_loanId] = block.timestamp;

        s._updateVaultBorrows(_loan.token, _loan.principal);

        TokenVault _vault = s.i_tokenVault[_loan.token];
        _vault.borrowFixed(_request.wallet, _loan.principal, _loan.annualRateBps);

        emit LoanTaken(
            _request.positionId, _loanId, _loan.token, _loan.principal, _loan.tenureSeconds, _loan.annualRateBps
        );
        return _loanId;
    }

    /// @notice Verify that a borrow request was signed by the configured request signer.
    /// @dev Reconstructs the EIP-191 message hash over the request fields and reverts
    ///      unless the recovered address matches `s_requestBorrowSigner`.
    /// @param s The diamond storage layout.
    /// @param _request The borrow request whose fields are hashed.
    /// @param _signature The signature to recover and check.
    function _verifyBorrowSignature(
        LibAppStorage.StorageLayout storage s,
        BorrowRequest calldata _request,
        bytes calldata _signature
    ) internal view {
        if (s.s_requestBorrowSigner == address(0)) {
            revert REQUEST_BORROW_SIGNER_NOT_SET();
        }

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _request.action,
                _request.positionId,
                _request.token,
                _request.amount,
                _request.tenureSeconds,
                _request.sourceChainId,
                _request.targetChainId,
                _request.nonce,
                _request.contractAddress,
                _request.wallet,
                _request.deadline
            )
        );
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, _signature);

        if (recoveredSigner != s.s_requestBorrowSigner) {
            revert REQUEST_BORROW_INVALID_SIGNATURE(recoveredSigner);
        }
    }

    /// @notice Repay a fixed-term loan for a position using interest-first allocation.
    /// @dev Clamps `_amount` to the outstanding balance, requires it to at least
    ///      cover accrued interest + penalty, reduces principal by the principal
    ///      portion only, closes the loan when principal hits zero, and forwards the
    ///      payment to the vault split into principal and interest.
    /// @param s The diamond storage layout.
    /// @param _positionId The position that owns the loan.
    /// @param _loanId The loan to repay.
    /// @param _amount Repayment amount (clamped to outstanding debt).
    /// @return The loan's remaining principal after repayment.
    function _repayLoanFor(LibAppStorage.StorageLayout storage s, uint256 _positionId, uint256 _loanId, uint256 _amount)
        internal
        returns (uint256)
    {
        _callerWhitelisted(s);
        Loan storage _loan = s.s_loans[_loanId];
        if (_loan.positionId != _positionId) revert NOT_LOAN_OWNER(_positionId);
        if (_loan.status != LoanStatus.FULFILLED) revert INACTIVE_LOAN();

        uint256 _loanDebt = _outstandingBalance(s, _loanId, block.timestamp);
        if (_loanDebt == 0) revert NO_OUTSTANDING_DEBT(_positionId, _loan.token);

        _allowanceAndBalanceCheck(_loan.token, _amount);

        if (_amount > _loanDebt) {
            _amount = _loanDebt;
        }

        uint256 _oldPrincipal = _loan.principal;

        // interest-first allocation: cover interest + penalty before any principal,
        // and reduce principal by the principal portion ONLY — never fold interest
        // into principal (which would re-accrue as compound interest: #12).
        uint256 _interestDue = _loanDebt - _oldPrincipal;

        // A repayment must at least cover the accrued interest + penalty. This
        // stops a dust repayment from resetting the interest anchor (escaping
        // accrued interest) — the maturity/penalty clock is already pinned to the
        // immutable origination time, so neither can be reset by a token payment (#6).
        if (_amount < _interestDue) revert REPAYMENT_BELOW_INTEREST(_amount, _interestDue);

        uint256 _principalRepaid = _amount - _interestDue;

        _loan.repaid += _amount;
        _loan.principal = _oldPrincipal - _principalRepaid;
        _loan.startTimestamp = block.timestamp;

        // If fully repaid, update loan status and move to closed loans
        if (_loan.principal == 0) {
            _loan.status = LoanStatus.REPAID;
            _removeLoanFromActive(s, _positionId, _loanId);
            s.s_positionClosedLoanIds[_positionId].push(_loanId);
        }

        TokenVault _vault = s.i_tokenVault[_loan.token];
        // Book debt/vault accounting against what the vault ACTUALLY received. A
        // fee-on-transfer token delivers less than the nominal `_amount`, so
        // reducing debt by `_amount` would credit the borrower more than the LPs
        // received (#6). Fail closed if the vault is short-changed.
        uint256 _before = IERC20(_loan.token).balanceOf(address(_vault));
        IERC20(_loan.token).safeTransferFrom(msg.sender, address(_vault), _amount);
        uint256 _received = IERC20(_loan.token).balanceOf(address(_vault)) - _before;
        if (_received != _amount) revert AMOUNT_MISMATCH(_received, _amount);

        s._updateVaultRepays(_loan.token, _principalRepaid);
        _vault.repayFixed(_principalRepaid, _amount - _principalRepaid, _loan.annualRateBps);

        emit LoanRepayment(_positionId, _loanId, _loan.token, _amount);
        return _loan.principal;
    }

    /// @notice Repay a fixed-term loan owned by the caller's position.
    /// @dev Resolves the caller's position id, then delegates to `_repayLoanFor`.
    /// @param s The diamond storage layout.
    /// @param _loanId The loan to repay.
    /// @param _amount Repayment amount (clamped to outstanding debt).
    /// @return The loan's remaining principal after repayment.
    function _repayLoan(LibAppStorage.StorageLayout storage s, uint256 _loanId, uint256 _amount)
        internal
        returns (uint256)
    {
        uint256 _positionId = _positionIdCheck(s);
        return _repayLoanFor(s, _positionId, _loanId, _amount);
    }

    /// @notice Borrow a token against the caller's position under an open-ended,
    ///         interest-accruing debt and disburse it from the token's vault.
    /// @dev Validates token support, utilization, and the post-borrow health factor;
    ///      capitalizes prior accrued interest into the stored debt while tracking
    ///      principal separately so the borrow tally moves by principal only.
    /// @param s The diamond storage layout.
    /// @param _token Token to borrow.
    /// @param _amount Amount to borrow.
    /// @return The position's updated total debt for the token (principal + interest).
    function _borrow(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount)
        internal
        returns (uint256)
    {
        uint256 _positionId = _positionIdCheck(s);
        if (_amount == 0) revert AMOUNT_ZERO();
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

        // Track principal separately and raise the borrow tally by principal only
        // (NOT capitalized interest), so it can be decremented symmetrically by
        // principal on repay. This keeps config.totalBorrows == outstanding
        // principal, which utilization / the borrow cap / interest pricing read.
        s.s_positionPrincipal[_positionId][_token] += _amount;
        s._updateVaultBorrows(_token, _amount);

        TokenVault _vault = s.i_tokenVault[_token];
        _vault.borrow(msg.sender, _amount);

        emit BorrowComplete(_positionId, _token, _amount);
        return s.s_positionBorrowed[_positionId][_token];
    }

    /// @notice Repay open-ended token debt for the caller's position.
    /// @dev Computes the interest-inclusive debt, clamps `_amount` to it, applies the
    ///      principal/interest split via `_repayStateChanges`, and forwards the
    ///      payment to the vault.
    /// @param s The diamond storage layout.
    /// @param _token Token whose debt is being repaid.
    /// @param _amount Repayment amount (clamped to outstanding debt).
    /// @return The position's remaining debt for the token after repayment.
    function _repay(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount) internal returns (uint256) {
        uint256 _positionId = _positionIdCheck(s);

        uint256 _debt = _calculateUserDebt(s, _positionId, _token, 0);
        if (_debt == 0) revert NO_OUTSTANDING_DEBT(_positionId, _token);

        _allowanceAndBalanceCheck(_token, _amount);

        if (_amount > _debt) {
            _amount = _debt;
        }

        RepayStateChangeParams memory _params =
            RepayStateChangeParams({positionId: _positionId, token: _token, amount: _amount});
        uint256 _principalRepaid = _repayStateChanges(s, _params);
        TokenVault _vault = s.i_tokenVault[_token];

        // Book against the amount actually received (fee-on-transfer safe, #6).
        uint256 _before = IERC20(_token).balanceOf(address(_vault));
        IERC20(_token).safeTransferFrom(msg.sender, address(_vault), _amount);
        uint256 _received = IERC20(_token).balanceOf(address(_vault)) - _before;
        if (_received != _amount) revert AMOUNT_MISMATCH(_received, _amount);
        _vault.repay(_principalRepaid, _amount - _principalRepaid);

        emit Repay(_positionId, _token, _amount);
        return _calculateUserDebt(s, _positionId, _token, 0);
    }

    /// @notice Apply the storage updates for an open-ended repayment and report the
    ///         principal portion repaid.
    /// @dev Reduces stored debt by the full `_params.amount`, but decrements the
    ///      principal tally (and vault borrows) by the principal portion only.
    /// @param s The diamond storage layout.
    /// @param _params Position id, token, and repayment amount.
    /// @return _principalRepaid The principal portion of the repayment.
    function _repayStateChanges(LibAppStorage.StorageLayout storage s, RepayStateChangeParams memory _params)
        internal
        returns (uint256 _principalRepaid)
    {
        uint256 _totalDebt = _calculateUserDebt(s, _params.positionId, _params.token, 0);
        s.s_positionBorrowed[_params.positionId][_params.token] = _totalDebt - _params.amount;
        s.s_positionBorrowedLastUpdate[_params.positionId][_params.token] = block.timestamp;

        // Interest-first allocation (mirrors `_repayLoanFor` / `_liquidateLoan`):
        // a repayment covers accrued interest before any principal. Reducing
        // principal first (the old behaviour) let an interest-only repayment
        // shrink the principal tally while interest went uncollected —
        // understating `totalBorrows` / utilization and mis-splitting the vault's
        // principal/interest booking so LP interest leaks to borrowers (#4).
        uint256 _principalOutstanding = s.s_positionPrincipal[_params.positionId][_params.token];
        uint256 _interestDue = _totalDebt > _principalOutstanding ? _totalDebt - _principalOutstanding : 0;
        _principalRepaid = _params.amount > _interestDue
            ? (_params.amount - _interestDue > _principalOutstanding ? _principalOutstanding : _params.amount - _interestDue)
            : 0;
        s.s_positionPrincipal[_params.positionId][_params.token] = _principalOutstanding - _principalRepaid;
        s._updateVaultRepays(_params.token, _principalRepaid);
    }

    /// @dev Protocol's reserve slice of an interest repayment, per the token's
    ///      `reserveFactor`. Applied to all interest, including penalty.
    function _allowanceAndBalanceCheck(address _token, uint256 _amount) internal view {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();
        if (_token != Constants.NATIVE_TOKEN) {
            if (IERC20(_token).allowance(msg.sender, address(this)) < _amount) revert INSUFFICIENT_ALLOWANCE();
            if (IERC20(_token).balanceOf(msg.sender) < _amount) revert INSUFFICIENT_BALANCE();
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

    /// @notice Register a new supported collateral token with its price feed and LTV.
    /// @dev Reverts on zero addresses, an LTV below 10%, or a token already supported.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to add.
    /// @param _pricefeed Price feed for the token.
    /// @param _tokenLTV Loan-to-value ratio in basis points (minimum 1000 = 10%).
    function _addCollateralToken(
        LibAppStorage.StorageLayout storage s,
        address _token,
        address _pricefeed,
        uint16 _tokenLTV
    ) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_pricefeed == address(0)) revert ADDRESS_ZERO();
        if (_tokenLTV < 1000) revert LTV_BELOW_TEN_PERCENT();
        // The LTV (origination borrow limit) must never exceed the liquidation
        // threshold, or a position could borrow up to `LTV·C` and land instantly
        // above the `threshold·C` liquidation trigger — a healthy max-borrow
        // position that is immediately liquidatable (#2). At onboarding the
        // threshold is the protocol default (90%), so bound the LTV to it here; the
        // threshold setter enforces the same invariant from the other direction.
        if (_tokenLTV > Constants.LIQUIDATION_THRESHOLD) {
            revert LTV_ABOVE_LIQUIDATION_THRESHOLD(_tokenLTV, Constants.LIQUIDATION_THRESHOLD);
        }
        if (s.s_supportedCollateralTokens[_token]) revert TOKEN_ALREADY_SUPPORTED_AS_COLLATERAL(_token);

        s.s_supportedCollateralTokens[_token] = true;
        s.s_allCollateralTokens.push(_token);
        s.s_tokenPriceFeed[_token] = _pricefeed;
        s.s_collateralTokenLTV[_token] = _tokenLTV;
        // Default the per-collateral liquidation threshold to the protocol default
        // (90%), preserving the historical flat-90%-of-raw behaviour until
        // governance tunes it per asset via `_setCollateralLiquidationThreshold`.
        s.s_collateralLiquidationThreshold[_token] = Constants.LIQUIDATION_THRESHOLD;

        emit CollateralTokenAdded(_token);
        emit CollateralTokenLTVUpdated(_token, 0, _tokenLTV);
    }

    /// @notice Remove a token from the supported collateral set.
    /// @dev Flips support off and swap-removes the token from the collateral list.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to remove.
    function _removeCollateralToken(LibAppStorage.StorageLayout storage s, address _token) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED_AS_COLLATERAL(_token);
        // Refuse to delist while positions still hold this collateral. Removing it
        // from `s_allCollateralTokens` makes the valuation loops count outstanding
        // holdings as zero USD, dropping solvent positions below the liquidation
        // threshold and letting public liquidators seize the (still price-fed)
        // collateral. Users must exit the token first.
        if (s.s_totalCollateralDeposited[_token] != 0) revert COLLATERAL_STILL_IN_USE(_token);

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

    /// @notice Set the protocol interest and penalty rates and propagate the interest
    ///         rate to every token vault so LP accrual tracks borrower pricing.
    /// @dev Reverts if either rate is zero.
    /// @param s The diamond storage layout.
    /// @param _newInterestRate New annual interest rate, in basis points.
    /// @param _newPenaltyRate New penalty rate, in basis points.
    function _setInterestRate(LibAppStorage.StorageLayout storage s, uint16 _newInterestRate, uint16 _newPenaltyRate)
        internal
    {
        if (_newInterestRate == 0) revert AMOUNT_ZERO();
        if (_newPenaltyRate == 0) revert AMOUNT_ZERO();
        s.s_interestRate = _newInterestRate;
        s.s_penaltyRate = _newPenaltyRate;

        // Keep every vault's accrual rate in sync with the protocol rate, so
        // depositor accrual tracks what borrowers actually pay (#4 — no frozen,
        // decoupled rate).
        address[] memory _tokens = s.s_allSupportedTokens;
        for (uint256 i; i < _tokens.length; ++i) {
            TokenVault _vault = s.i_tokenVault[_tokens[i]];
            if (address(_vault) != address(0)) _vault.setInterestRate(_newInterestRate);
        }

        emit InterestRateUpdated(_newInterestRate, _newPenaltyRate);
    }

    /// @notice Update the loan-to-value ratio for a supported collateral token.
    /// @dev Reverts on a zero token, an LTV below 10%, or an unsupported token.
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to update.
    /// @param _tokenNewLTV New loan-to-value ratio in basis points (minimum 1000).
    function _setCollateralTokenLtv(LibAppStorage.StorageLayout storage s, address _token, uint16 _tokenNewLTV)
        internal
    {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (_tokenNewLTV < 1000) revert LTV_BELOW_TEN_PERCENT();
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED_AS_COLLATERAL(_token);
        // Keep LTV <= the token's effective liquidation threshold (#2). Without this
        // an admin could raise a token's LTV above its (possibly per-asset tuned)
        // threshold and let borrowers open positions that are liquidatable on
        // origination. Compared against the live effective threshold, so it composes
        // with `_setCollateralLiquidationThreshold`.
        uint16 _effectiveThreshold = _getCollateralLiquidationThreshold(s, _token);
        if (_tokenNewLTV > _effectiveThreshold) {
            revert LTV_ABOVE_LIQUIDATION_THRESHOLD(_tokenNewLTV, _effectiveThreshold);
        }

        uint16 _oldLTV = s.s_collateralTokenLTV[_token];
        s.s_collateralTokenLTV[_token] = _tokenNewLTV;

        emit CollateralTokenLTVUpdated(_token, _oldLTV, _tokenNewLTV);
    }

    /// @notice Set a collateral token's liquidation threshold in basis points.
    /// @dev The threshold is the debt-to-collateral ratio at which the position
    ///      becomes liquidatable. It MUST be >= the token's LTV (so a healthy
    ///      max-borrow position is never immediately liquidatable) and <= 100%
    ///      (so `threshold + liquidationBonus` stays within the collateral value).
    /// @param s The diamond storage layout.
    /// @param _token Collateral token to configure.
    /// @param _threshold New liquidation threshold in basis points.
    function _setCollateralLiquidationThreshold(
        LibAppStorage.StorageLayout storage s,
        address _token,
        uint16 _threshold
    ) internal {
        if (_token == address(0)) revert ADDRESS_ZERO();
        if (!s.s_supportedCollateralTokens[_token]) revert TOKEN_NOT_SUPPORTED_AS_COLLATERAL(_token);
        if (_threshold < s.s_collateralTokenLTV[_token] || _threshold > Constants.BASIS_POINTS_SCALE) {
            revert BAD_RATE();
        }

        uint16 _old = s.s_collateralLiquidationThreshold[_token];
        s.s_collateralLiquidationThreshold[_token] = _threshold;

        emit CollateralLiquidationThresholdSet(_token, _old, _threshold);
    }

    /// @notice The effective liquidation threshold for a collateral token.
    /// @dev Falls back to the protocol default (`LIQUIDATION_THRESHOLD`) when unset
    ///      (a zero entry), so pre-configuration collaterals behave as before.
    function _getCollateralLiquidationThreshold(LibAppStorage.StorageLayout storage s, address _token)
        internal
        view
        returns (uint16)
    {
        uint16 _threshold = s.s_collateralLiquidationThreshold[_token];
        return _threshold == 0 ? uint16(Constants.LIQUIDATION_THRESHOLD) : _threshold;
    }

    /// @notice Threshold-weighted USD value of a position's collateral — the debt
    ///         ceiling above which the position is liquidatable.
    /// @dev Each collateral's raw USD value is scaled by its effective liquidation
    ///      threshold (per-asset, defaulting to 90%). Mirrors
    ///      `_getPositionUtilizableCollateralValue` but with the liquidation
    ///      threshold instead of the LTV.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The threshold-weighted collateral value.
    function _getPositionLiquidationThresholdValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = 0;
        address[] memory _tokens = s.s_allCollateralTokens;
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _token = _tokens[i];
            uint16 _threshold = _getCollateralLiquidationThreshold(s, _token);
            uint256 _usdValue = _getPositionCollateralTokenValue(s, _positionId, _token);
            _totalValue += (_usdValue * _threshold) / Constants.BASIS_POINTS_SCALE;
        }
        return _totalValue;
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

    /// @notice Total USD value of all collateral held by a position (no LTV haircut).
    /// @param s The diamond storage layout.
    /// @param _positionId The position to value.
    /// @return The summed USD value across every supported collateral token.
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

    /// @notice Remaining USD value a position can still borrow against.
    /// @dev LTV-weighted collateral value minus current open + active-loan debt,
    ///      floored at zero.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The borrowable USD headroom for the position.
    function _getPositionBorrowableCollateralValue(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalValue = _getPositionUtilizableCollateralValue(s, _positionId);
        uint256 _debt = _getPositionBorrowedValue(s, _positionId) + _totalActiveDebt(s, _positionId);
        if (_debt >= _totalValue) {
            return 0;
        }
        return _totalValue - _debt;
    }

    /// @notice LTV-weighted USD value of a position's collateral (the borrowing base).
    /// @dev Each collateral's USD value is scaled by its per-token LTV.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The LTV-weighted collateral value.
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

    /// @notice Total USD value of a position's open-ended (non-fixed-term) debt
    ///         across all supported tokens, including accrued interest.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The summed USD debt value.
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

    /// @notice Compute a position's health factor, optionally including a prospective
    ///         additional borrow.
    /// @dev Returns LTV-weighted collateral × PRECISION / total debt (open + active +
    ///      `_currentBorrowValue`); returns the max (collateral × PRECISION) when there
    ///      is no debt.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @param _currentBorrowValue Prospective extra borrow value in USD (0 to ignore).
    /// @return The health factor scaled by 1e18.
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

        uint256 _from = s.s_positionBorrowedLastUpdate[_positionId][_token];
        uint256 _timeElapsed = block.timestamp - _from;

        // Fixed APR (#11): price interest at the protocol-set rate over the actual
        // elapsed time. Pricing off live utilization let a same-block utilization
        // spike retroactively reprice a borrower's whole interval and force a
        // wrongful liquidation; the fixed rate removes that manipulable input and
        // keeps borrower debt coupled to the vault's (same-rate) LP accrual.
        uint256 interestRate = s.s_interestRate;
        uint256 factor = ((interestRate * _timeElapsed) * 1e18) / (10000 * 365 days);
        debt = _amount + _tokenBorrows + ((_tokenBorrows * factor) / 1e18);

        return debt;
    }

    /// @notice Total USD value of a position's active fixed-term loans, including
    ///         accrued interest and any penalty.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to evaluate.
    /// @return The summed USD value of all active loans' outstanding balances.
    function _totalActiveDebt(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256)
    {
        uint256 _totalDebt = 0;

        uint256[] memory _ids = s.s_positionActiveLoanIds[_positionId];
        for (uint256 i = 0; i < _ids.length; i++) {
            Loan memory _loan = s.s_loans[_ids[i]];
            (, uint256 _debt) = s._getTokenValueInUSD(_loan.token, _outstandingBalance(s, _ids[i], block.timestamp));
            _totalDebt += _debt;
        }
        return _totalDebt;
    }

    /// @notice Compute a fixed-term loan's outstanding balance (principal + accrued
    ///         interest, plus a post-maturity penalty) at a given timestamp.
    /// @dev Returns 0 for any non-FULFILLED loan. Base interest accrues from the
    ///      resettable anchor up to maturity only; the penalty accrues against the
    ///      fixed maturity.
    /// @param _loan The loan to value.
    /// @param _originationTime The IMMUTABLE loan origination timestamp. Maturity
    ///        (and therefore the penalty window) is measured against this, so a
    ///        partial repayment that resets the interest anchor `startTimestamp`
    ///        cannot move the maturity / penalty clock (#6).
    /// @param _timestamp The timestamp at which to value the loan.
    /// @return The total amount owed at `_timestamp`.
    function _outstandingBalance(Loan memory _loan, uint256 _originationTime, uint256 _timestamp)
        internal
        pure
        returns (uint256)
    {
        if (_loan.status != LoanStatus.FULFILLED) return 0;

        uint256 _maturity = _originationTime + _loan.tenureSeconds;

        // Base interest accrues from the (resettable) interest anchor up to
        // maturity — never past it, regardless of how many times it is reset.
        uint256 _interestEnd = _timestamp < _maturity ? _timestamp : _maturity;
        uint256 _interestElapsed = _interestEnd > _loan.startTimestamp ? _interestEnd - _loan.startTimestamp : 0;

        uint256 _interest = (_loan.principal * _loan.annualRateBps * _interestElapsed)
            / (Constants.BASIS_POINTS_SCALE_256 * Constants.ONE_YEAR);
        uint256 _totalOwed = _loan.principal + _interest;

        // Penalty accrues from the later of maturity and the last settlement point.
        // The interest anchor `startTimestamp` is advanced by a valid repayment ONLY
        // after that repayment has fully settled the accrued interest+penalty to date
        // (`_repayLoanFor` interest-first guard `_amount >= _interestDue`), so
        // `startTimestamp > _maturity` implies penalty was already paid up to
        // `startTimestamp`. Liquidation never advances the anchor, so its surviving
        // principal keeps accruing penalty from maturity. Flooring the penalty window
        // here stops a partial repayment on an overdue loan from re-charging the whole
        // post-maturity penalty window on the surviving principal every block (#M-02).
        uint256 _penaltyStart = _loan.startTimestamp > _maturity ? _loan.startTimestamp : _maturity;
        if (_timestamp > _penaltyStart) {
            uint256 penaltyTime = _timestamp - _penaltyStart;
            uint256 penalty = (_totalOwed * (uint256(_loan.annualRateBps) + _loan.penaltyRateBps) * penaltyTime)
                / (Constants.BASIS_POINTS_SCALE_256 * Constants.ONE_YEAR);
            _totalOwed += penalty;
        }

        return _totalOwed;
    }

    /// @notice Compute a stored loan's outstanding balance at a given timestamp.
    /// @dev Resolves the immutable origination time (`s_loanStartTime`, falling back
    ///      to the loan's `startTimestamp`) and delegates to the pure overload.
    /// @param s The diamond storage layout.
    /// @param _loanId The loan to value.
    /// @param _timestamp The timestamp at which to value the loan.
    /// @return The total amount owed at `_timestamp`.
    function _outstandingBalance(LibAppStorage.StorageLayout storage s, uint256 _loanId, uint256 _timestamp)
        internal
        view
        returns (uint256)
    {
        Loan memory _loan = s.s_loans[_loanId];
        uint256 _origination = s.s_loanStartTime[_loanId] == 0 ? _loan.startTimestamp : s.s_loanStartTime[_loanId];
        return _outstandingBalance(_loan, _origination, _timestamp);
    }

    function _transferToken(address _token, address _to, uint256 _amount) internal {
        if (_to == address(0)) revert ADDRESS_ZERO();
        if (_amount == 0) revert AMOUNT_ZERO();

        if (_token == Constants.NATIVE_TOKEN) {
            (bool sent,) = _to.call{value: _amount}("");
            if (!sent) revert TRANSFER_FAILED();
            return;
        } else {
            IERC20(_token).safeTransfer(_to, _amount);
        }
    }

    function _validateAmount(address _token, uint256 _amount) internal view {
        if (_amount == 0) revert AMOUNT_ZERO();
        if (_token == Constants.NATIVE_TOKEN) {
            if (msg.value != _amount) revert AMOUNT_MISMATCH(msg.value, _amount);
        } else if (msg.value != 0) {
            // The collateral entrypoint is `payable` for the native path; reject ETH
            // sent alongside an ERC20 deposit so it can't be silently trapped in the
            // diamond (see lead: ERC20 deposit traps ETH).
            revert AMOUNT_MISMATCH(msg.value, 0);
        }
    }

    /// @notice List the active loan ids for a position.
    /// @param s The diamond storage layout.
    /// @param _positionId The position to query.
    /// @return The position's active loan ids.
    function _getUserActiveLoanIds(LibAppStorage.StorageLayout storage s, uint256 _positionId)
        internal
        view
        returns (uint256[] memory)
    {
        return s.s_positionActiveLoanIds[_positionId];
    }

    /// @notice List every loan id across the protocol whose status is FULFILLED.
    /// @param s The diamond storage layout.
    /// @return The ids of all currently active loans.
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

    /// @notice Return the full details of a loan, including its current outstanding debt.
    /// @dev `principal` and `startTimestamp` fall back to the immutable `s_loanPrincipal`
    ///      / `s_loanStartTime` records when the live loan fields have been mutated.
    /// @param s The diamond storage layout.
    /// @param _loanId The loan to read.
    /// @return positionId The owning position id.
    /// @return token The borrowed token.
    /// @return principal The loan principal (original if the live value is zero).
    /// @return repaid The cumulative amount repaid.
    /// @return tenureSeconds The loan tenure in seconds.
    /// @return startTimestamp The immutable origination timestamp.
    /// @return debt The current outstanding balance at `block.timestamp`.
    /// @return annualRateBps The annual interest rate in basis points.
    /// @return penaltyRateBps The penalty rate in basis points.
    /// @return status The loan status as a uint8.
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
            loan.principal == 0 ? s.s_loanPrincipal[_loanId] : loan.principal,
            loan.repaid,
            loan.tenureSeconds,
            s.s_loanStartTime[_loanId] == 0 ? loan.startTimestamp : s.s_loanStartTime[_loanId],
            _outstandingBalance(s, _loanId, block.timestamp),
            loan.annualRateBps,
            loan.penaltyRateBps,
            uint8(loan.status)
        );
    }
}
