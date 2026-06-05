// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";

import {LibInterestRateModel} from "../contracts/libraries/LibInterestRateModel.sol";
import {LibProtocol} from "../contracts/libraries/LibProtocol.sol";

import {Loan, LoanStatus} from "../contracts/models/Protocol.sol";

contract ProtocolLibTest is Base {
    function setUp() public override {
        super.setUp();
    }

    function testCalculateSimpleInterest() public pure {
        uint256 principal = 1000 ether;
        uint256 rateBasisPoints = 500; // 5%
        uint256 timeInSeconds = 365 days; // 1 year

        uint256 interest = LibInterestRateModel.calculateSimpleInterest(principal, rateBasisPoints, timeInSeconds);

        // Expected interest: 1000 * 0.05 * 1 = 50 ether
        assertEq(interest, 50 ether);
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

        uint256 outstanding = LibProtocol._outstandingBalance(_loan, block.timestamp + 365 days);

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

        uint256 outstanding = LibProtocol._outstandingBalance(_loan, block.timestamp + (2 * 365 days));

        // Expected outstanding balance: 2000 + 20% interest after first year + 25% interest p.a after penalty = 3000 ether
        assertEq(outstanding, 3000 ether);
    }
}
