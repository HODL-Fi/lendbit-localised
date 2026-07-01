// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BorrowRequest} from "../../contracts/models/Protocol.sol";

/// @notice PoCs for the 2026-07-01 review findings that were NOT already covered
///         by the 2026-06-26 remediations.
/// @dev #1 (signed-borrow health) and #7 (keeper whitelist on sendRequest) are
///      documented accepted design decisions (see KNOWN_ISSUES.md / scope.md) and
///      are intentionally not "fixed" here.
contract AuditReport0701Test is Base {
    function _sign(uint256 _pk, BorrowRequest memory _r) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                _r.action,
                _r.positionId,
                _r.token,
                _r.amount,
                _r.tenureSeconds,
                _r.sourceChainId,
                _r.targetChainId,
                _r.nonce,
                _r.contractAddress,
                _r.wallet,
                _r.deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_pk, MessageHashUtils.toEthSignedMessageHash(messageHash));
        return abi.encodePacked(r, s, v);
    }

    // ------------------------------------------------------------------
    // #2 — Request-borrow loans record an immutable maturity anchor.
    // ------------------------------------------------------------------
    function test_requestBorrow_maturity_anchor_is_immutable() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000e18);

        uint256 signerPk = 0xA11CE;
        positionManagerF.setRequestBorrowSigner(vm.addr(signerPk));

        uint256 tenure = 30 days;
        BorrowRequest memory request = BorrowRequest({
            action: "BORROW_REQUEST",
            positionId: positionId,
            token: address(token4),
            amount: 100e6,
            tenureSeconds: tenure,
            sourceChainId: block.chainid,
            targetChainId: block.chainid,
            nonce: 1,
            contractAddress: address(protocolF),
            wallet: user1,
            deadline: 0
        });

        vm.prank(user1);
        uint256 loanId = protocolF.requestBorrow(request, _sign(signerPk, request));

        // The immutable origination anchor (`s_loanStartTime`) is recorded at request
        // time. Pre-fix it stayed 0, so `_outstandingBalance` fell back to the
        // resettable `_loan.startTimestamp`. Read it from storage (a stable snapshot).
        (,,,,, uint256 origination,,,,) = gettersF.getLoanDetails(loanId);
        assertGt(origination, 0, "origination anchor recorded at requestBorrow");

        // Go 10 days past maturity, then make a partial repayment (which resets the
        // live `_loan.startTimestamp`).
        vm.warp(origination + tenure + 10 days);
        updatePricefeedsData();
        uint256 debtOverdue = gettersF.getOutstandingDebtForLoan(loanId);
        (,, uint256 principalBefore,,,,,,,) = gettersF.getLoanDetails(loanId);
        uint256 interestDue = debtOverdue - principalBefore;

        uint256 payback = interestDue + 1e6; // cover interest + a little principal
        token4.mint(user1, payback);
        vm.startPrank(user1);
        token4.approve(address(diamond), payback);
        protocolF.repayLoan(loanId, payback);
        vm.stopPrank();

        // Maturity anchor did NOT move: the loan is still measured against its
        // origination, so it stays past maturity and keeps accruing penalty (pre-fix
        // the anchor reset to the repay time, escaping the penalty and extending tenure).
        (,,,,, uint256 startTsAfter,,,,) = gettersF.getLoanDetails(loanId);
        assertEq(startTsAfter, origination, "origination anchor is immutable across partial repay");
        assertLt(origination + tenure, block.timestamp, "loan is still past its fixed maturity");
    }

    // ------------------------------------------------------------------
    // #4 — Open-ended repayment is interest-first (principal tally untouched
    //      when only interest is repaid).
    // ------------------------------------------------------------------
    function test_openEnded_repay_is_interest_first() public {
        createVaultAndFund(1_000_000e18);
        uint256 positionId = depositCollateralFor(user1, address(token1), 10_000e18);

        uint256 borrowAmount = 100e6;
        vm.prank(user1);
        protocolF.borrow(address(token4), borrowAmount);

        uint256 principalTallyBefore = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        assertEq(principalTallyBefore, borrowAmount, "principal tally == borrowed principal");

        vm.warp(block.timestamp + 180 days);
        updatePricefeedsData();

        uint256 debt = gettersF.getBorrowDetails(positionId, address(token4));
        uint256 interestDue = debt - borrowAmount;
        assertGt(interestDue, 0, "loan accrued interest");
        assertLt(interestDue, borrowAmount, "interest is below principal for this horizon");

        // Repay exactly the accrued interest. Interest-first means principal (and the
        // borrow tally / utilization) are untouched; pre-fix (principal-first) the
        // tally would have dropped by `interestDue`, understating utilization.
        token4.mint(user1, interestDue);
        vm.startPrank(user1);
        token4.approve(address(diamond), interestDue);
        protocolF.repay(address(token4), interestDue);
        vm.stopPrank();

        uint256 principalTallyAfter = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        assertEq(principalTallyAfter, borrowAmount, "interest-only repay does not reduce principal");
    }
}
