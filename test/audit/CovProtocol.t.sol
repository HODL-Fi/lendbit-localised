// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {Base} from "../Base.t.sol";
import {LibProtocol} from "../../contracts/libraries/LibProtocol.sol";

import "../../contracts/models/Protocol.sol";
import "../../contracts/models/Error.sol";
import "../../contracts/models/Event.sol";

/// @title CovProtocol — branch-coverage tests for LibProtocol validation / revert edges
/// @notice Targets revert and conditional branches not exercised by Protocol.t.sol:
///         _takeLoan / _borrow health-factor + over-utilization, the full _requestBorrow
///         validation gauntlet, _repay / _repayLoanFor debt-state edges, and the pure
///         _outstandingBalance non-FULFILLED branch.
contract CovProtocolTest is Base {
    uint256 internal constant SIGNER_KEY = 0xA11CE;

    function setUp() public override {
        super.setUp();
    }

    // -------------------------------------------------------------------------
    // request-builder + signing helpers (mirrors Protocol.t.sol)
    // -------------------------------------------------------------------------

    function _baseRequest(uint256 _positionId, address _wallet) internal view returns (BorrowRequest memory) {
        return BorrowRequest({
            action: "BORROW_REQUEST",
            positionId: _positionId,
            token: address(token4),
            amount: 1000 * 1e6,
            tenureSeconds: 30 days,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: 1,
            contractAddress: address(protocolF),
            wallet: _wallet,
            deadline: 0
        });
    }

    function _borrowRequestDigest(BorrowRequest memory _request) internal pure returns (bytes32) {
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
        return MessageHashUtils.toEthSignedMessageHash(messageHash);
    }

    function _sign(BorrowRequest memory _request, uint256 _key) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_key, _borrowRequestDigest(_request));
        return abi.encodePacked(r, s, v);
    }

    // =========================================================================
    //                       _takeLoan  /  _borrow  edges
    // =========================================================================

    /// _takeLoan: post-borrow health factor below MIN -> HEALTH_FACTOR_TOO_LOW
    function testTakeLoanFailsForHealthFactorTooLow() public {
        createVaultAndFund(1_000_000e18);
        // Thin collateral: 1 token1 = $1500, utilizable $1200.
        depositCollateralFor(user1, address(token1), 1e18);

        vm.startPrank(user1);
        // 1000 token4 * $250 = $250k borrow value; utilizable collateral $1200 -> HF = 4.8e15 < 1e18.
        vm.expectRevert(abi.encodeWithSelector(HEALTH_FACTOR_TOO_LOW.selector, uint256(4_800_000_000_000_000)));
        protocolF.takeLoan(address(token4), 1000 * 1e6, 30 days);
        vm.stopPrank();
    }

    /// _borrow: open-ended borrow whose value sinks HF below MIN -> HEALTH_FACTOR_TOO_LOW
    function testBorrowFailsForHealthFactorTooLow() public {
        createVaultAndFund(1_000_000e18);
        depositCollateralFor(user1, address(token1), 1e18);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(HEALTH_FACTOR_TOO_LOW.selector, uint256(4_800_000_000_000_000)));
        protocolF.borrow(address(token4), 1000 * 1e6);
        vm.stopPrank();
    }

    /// _borrow: borrow amount above the vault utilization cap -> TOKEN_OVERUTILIZATION
    function testBorrowFailsForOverUtilization() public {
        createVaultAndFund(1000 * 1e6); // small vault
        depositCollateralFor(user1, address(token1), 1000 * 1e18); // ample collateral

        vm.startPrank(user1);
        vm.expectRevert(TOKEN_OVERUTILIZATION.selector);
        protocolF.borrow(address(token4), 901 * 1e6); // > 90% of deposits
        vm.stopPrank();
    }

    /// _borrow: second borrow of the same token takes the `_tokenBorrow != 0` else branch
    function testBorrowSecondTimeSameTokenCapitalizesInterest() public {
        createVaultAndFund(1_000_000e18);
        depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        vm.startPrank(user1);
        uint256 firstDebt = protocolF.borrow(address(token4), 1000 * 1e6);
        assertEq(firstDebt, 1000 * 1e6, "first borrow sets principal directly");
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days); // accrue interest so the else branch capitalizes it
        updatePricefeedsData(); // refresh oracle timestamps past the staleness window

        vm.prank(user1);
        uint256 secondDebt = protocolF.borrow(address(token4), 1000 * 1e6);

        // Second debt = prior (with accrued interest) + new principal > 2x principal
        assertGt(secondDebt, 2000 * 1e6, "second borrow capitalizes accrued interest");
    }

    // =========================================================================
    //                       _requestBorrow validation gauntlet
    // =========================================================================

    function testRequestBorrowFailsForEmptyAction() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        BorrowRequest memory request = _baseRequest(positionId, user1);
        request.action = "";

        vm.prank(user1);
        vm.expectRevert(EMPTY_STRING.selector);
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsForZeroWallet() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        BorrowRequest memory request = _baseRequest(positionId, address(0));

        vm.prank(user1);
        vm.expectRevert(ADDRESS_ZERO.selector);
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsForZeroContractAddress() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        BorrowRequest memory request = _baseRequest(positionId, user1);
        request.contractAddress = address(0);

        vm.prank(user1);
        vm.expectRevert(ADDRESS_ZERO.selector);
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsForZeroAmount() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        BorrowRequest memory request = _baseRequest(positionId, user1);
        request.amount = 0;

        vm.prank(user1);
        vm.expectRevert(AMOUNT_ZERO.selector);
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsForUnsupportedToken() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        BorrowRequest memory request = _baseRequest(positionId, user1);
        request.token = address(token3); // never registered as a borrowable token

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token3)));
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsForNoPosition() public {
        createVaultAndFund(1_000_000e18);
        // user2 is whitelisted but has no position.
        BorrowRequest memory request = _baseRequest(1, user2);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user2));
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsForTargetChainMismatch() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        BorrowRequest memory request = _baseRequest(positionId, user1);
        request.targetChainId = block.chainid + 1;

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(REQUEST_BORROW_TARGET_CHAIN_MISMATCH.selector, block.chainid, block.chainid + 1)
        );
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsForContractMismatch() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        BorrowRequest memory request = _baseRequest(positionId, user1);
        request.contractAddress = address(0xBEEF); // non-zero but not this diamond

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(REQUEST_BORROW_CONTRACT_MISMATCH.selector, address(diamond), address(0xBEEF))
        );
        protocolF.requestBorrow(request, "");
    }

    function testRequestBorrowFailsWhenSignerNotSet() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);
        // signer left unset (address(0))

        BorrowRequest memory request = _baseRequest(positionId, user1);
        bytes memory signature = _sign(request, SIGNER_KEY);

        vm.prank(user1);
        vm.expectRevert(REQUEST_BORROW_SIGNER_NOT_SET.selector);
        protocolF.requestBorrow(request, signature);
    }

    function testRequestBorrowFailsForInvalidSignature() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);
        positionManagerF.setRequestBorrowSigner(vm.addr(SIGNER_KEY));

        BorrowRequest memory request = _baseRequest(positionId, user1);
        bytes memory wrongSignature = _sign(request, 0xBAD); // signed by the wrong key

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(REQUEST_BORROW_INVALID_SIGNATURE.selector, vm.addr(0xBAD)));
        protocolF.requestBorrow(request, wrongSignature);
    }

    function testRequestBorrowFailsForReusedNonce() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);
        positionManagerF.setRequestBorrowSigner(vm.addr(SIGNER_KEY));

        BorrowRequest memory request = _baseRequest(positionId, user1);
        bytes memory signature = _sign(request, SIGNER_KEY);

        vm.startPrank(user1);
        protocolF.requestBorrow(request, signature); // first use marks the nonce
        vm.expectRevert(abi.encodeWithSelector(REQUEST_BORROW_NONCE_USED.selector, user1, uint256(1)));
        protocolF.requestBorrow(request, signature); // replay same nonce
        vm.stopPrank();
    }

    // =========================================================================
    //                       _repay  /  _repayLoanFor  edges
    // =========================================================================

    /// _repay: token has no open debt for the position -> NO_OUTSTANDING_DEBT
    function testRepayFailsForNoOutstandingDebt() public {
        createVaultAndFund(1_000_000e18);
        depositCollateralFor(user1, address(token1), 1000 * 1e18); // position, but no token4 borrow

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(NO_OUTSTANDING_DEBT.selector, uint256(2), address(token4)));
        protocolF.repay(address(token4), 1000 * 1e6);
    }

    /// _repayLoanFor: repaying a loan that is already fully repaid (status REPAID) -> INACTIVE_LOAN
    function testRepayLoanForFailsForInactiveLoan() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        vm.startPrank(user1);
        uint256 loanId = protocolF.takeLoan(address(token4), 1000 * 1e6, 365 days);

        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        token4.mint(user1, debt);
        token4.approve(address(diamond), debt);
        protocolF.repayLoanFor(positionId, loanId, debt); // fully repays -> status REPAID

        // Second repayment on the now-inactive loan reverts.
        token4.mint(user1, 1000 * 1e6);
        token4.approve(address(diamond), 1000 * 1e6);
        vm.expectRevert(INACTIVE_LOAN.selector);
        protocolF.repayLoanFor(positionId, loanId, 1000 * 1e6);
        vm.stopPrank();
    }

    /// _repayLoanFor: repayment below accrued interest -> REPAYMENT_BELOW_INTEREST
    function testRepayLoanForFailsForRepaymentBelowInterest() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000 * 1e18);

        vm.startPrank(user1);
        uint256 loanId = protocolF.takeLoan(address(token4), 1000 * 1e6, 365 days);

        vm.warp(block.timestamp + 100 days); // accrue interest > 0

        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        uint256 interestDue = debt - 1000 * 1e6;
        assertGt(interestDue, 1, "interest must have accrued");

        // Pay 1 unit: passes allowance/balance, below interestDue after clamp.
        token4.mint(user1, 1);
        token4.approve(address(diamond), 1);
        vm.expectRevert(abi.encodeWithSelector(REPAYMENT_BELOW_INTEREST.selector, uint256(1), interestDue));
        protocolF.repayLoanFor(positionId, loanId, 1);
        vm.stopPrank();
    }

    // =========================================================================
    //                  borrowable-value + outstanding-balance edges
    // =========================================================================

    /// _getPositionBorrowableCollateralValue: debt >= collateral value -> returns 0
    function testBorrowableCollateralValueZeroWhenUnderwater() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10 * 1e18); // $15k, utilizable $12k

        vm.startPrank(user1);
        // Borrow ~$10k of token4 (40 * $250), then let post-maturity penalty + interest
        // push outstanding debt above the collateral value.
        protocolF.takeLoan(address(token4), 40 * 1e6, 30 days);
        vm.stopPrank();

        vm.warp(block.timestamp + 3650 days); // debt grows far past collateral
        updatePricefeedsData(); // refresh oracle timestamps past the staleness window

        assertGt(gettersF.getTotalActiveDebt(positionId), gettersF.getPositionUtilizableCollateralValue(positionId));
        assertEq(gettersF.getPositionBorrowableCollateralValue(positionId), 0, "no borrowable headroom when underwater");
    }

    /// _outstandingBalance (pure): a non-FULFILLED loan returns 0
    function testOutstandingBalanceNonFulfilledReturnsZero() public view {
        Loan memory loan = Loan({
            positionId: 1,
            token: address(0),
            principal: 1000 ether,
            repaid: 0,
            startTimestamp: block.timestamp,
            tenureSeconds: 365 days,
            annualRateBps: 2000,
            penaltyRateBps: 500,
            status: LoanStatus.REPAID
        });

        uint256 owed = LibProtocol._outstandingBalance(loan, loan.startTimestamp, block.timestamp + 730 days);
        assertEq(owed, 0, "non-FULFILLED loan owes nothing");
    }
}
