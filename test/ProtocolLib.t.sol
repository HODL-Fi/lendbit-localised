// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";

import {LibProtocol} from "../contracts/libraries/LibProtocol.sol";

import {Loan, LoanStatus} from "../contracts/models/Protocol.sol";

contract ProtocolLibTest is Base {
    function setUp() public override {
        super.setUp();
    }

    function testOutstandingBalance() public view {
        uint256 principal = 2000 ether;
        uint256 repaid = 500 ether;

        Loan memory _loan = Loan({
            positionId: 1,
            token: address(0),
            principal: principal - repaid,
            repaid: repaid,
            startTimestamp: block.timestamp,
            tenureSeconds: 365 days,
            annualRateBps: 2000, // 20%
            penaltyRateBps: 5000, // 5%
            status: LoanStatus.FULFILLED
        });

        uint256 outstanding = LibProtocol._outstandingBalance(_loan, _loan.startTimestamp, block.timestamp + 365 days);

        // Expected outstanding balance: (2000 - 500) + 20% interest p.a  = 1800 ether
        assertEq(outstanding, 1800 ether);
    }

    function testOutstandingBalanceWithPenalty() public view {
        uint256 principal = 2000 ether;
        uint256 repaid = 0;

        Loan memory _loan = Loan({
            positionId: 1,
            token: address(0),
            principal: principal,
            repaid: repaid,
            startTimestamp: block.timestamp,
            tenureSeconds: 365 days,
            annualRateBps: 2000, // 20%
            penaltyRateBps: 500, // 5%
            status: LoanStatus.FULFILLED
        });

        uint256 outstanding = LibProtocol._outstandingBalance(_loan, _loan.startTimestamp, block.timestamp + (2 * 365 days));

        // Expected outstanding balance: 2000 + 20% interest after first year + 25% interest p.a after penalty = 3000 ether
        assertEq(outstanding, 3000 ether);
    }
}
