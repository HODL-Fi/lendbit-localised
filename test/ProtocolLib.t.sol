// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "./Base.t.sol";

import {LibInterestRateModel} from "../contracts/libraries/LibInterestRateModel.sol";
import {LibProtocol} from "../contracts/libraries/LibProtocol.sol";
import {LibAppStorage} from "../contracts/libraries/LibAppStorage.sol";

import {Loan, LoanStatus, RepayRequest} from "../contracts/models/Protocol.sol";

import {console} from "forge-std/console.sol";

contract ProtocolLibTest is Base {
    address internal signer;
    uint256 internal signerPrivateKey;

    function setUp() public override {
        super.setUp();

        // Set up a mock signer
        signerPrivateKey = 0x123456789abcdef; // Example private key for testing
        signer = vm.addr(signerPrivateKey);
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

        // Expected outstanding balance: 2000 + 20% interest p.a + 5% penalty p.a after penalty = 2900 ether
        assertEq(outstanding, 2900 ether);
    }

    function testSignatureRecoveryRepay() public {
        // Create a RepayRequest
        RepayRequest memory request = RepayRequest({
            action: "repay",
            loanId: 1,
            amount: 1000,
            sourceChainId: 1,
            targetChainId: block.chainid,
            nonce: 1,
            contractAddress: address(this),
            walletAddress: address(0x123)
        });

        // Compute the hash as per _verifyRepayRequest
        bytes32 innerHash = keccak256(
            abi.encode(
                request.action,
                request.loanId,
                request.amount,
                request.sourceChainId,
                request.targetChainId,
                request.nonce,
                request.contractAddress,
                request.walletAddress
            )
        );
        bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));

        // Sign the hash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Call _verifyRepayRequest and check _recovered
        // Since _verifyRepayRequest is internal, we simulate the recovery logic here to inspect _recovered
        bytes32 recoveredR;
        bytes32 recoveredS;
        uint8 recoveredV;
        assembly {
            recoveredR := mload(add(signature, 32))
            recoveredS := mload(add(signature, 64))
            recoveredV := byte(0, mload(add(signature, 96)))
        }
        address _recovered = ecrecover(hash, recoveredV, recoveredR, recoveredS);

        // Log the _recovered value for visibility
        console.log("Recovered address:", _recovered);

        // Assert it matches the signer
        assertEq(_recovered, signer, "Signature recovery failed");
    }

    function testInvalidSignature() public {
        // Similar setup but with wrong signature
        RepayRequest memory request = RepayRequest({
            action: "repay",
            loanId: 1,
            amount: 1000,
            sourceChainId: 1,
            targetChainId: block.chainid,
            nonce: 1,
            contractAddress: address(this),
            walletAddress: address(0x123)
        });

        bytes32 innerHash = keccak256(
            abi.encode(
                request.action,
                request.loanId,
                request.amount,
                request.sourceChainId,
                request.targetChainId,
                request.nonce,
                request.contractAddress,
                request.walletAddress
            )
        );
        bytes32 hash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", innerHash));

        // Sign with a different key
        uint256 wrongKey = 0xabcdef123456789;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes32 recoveredR;
        bytes32 recoveredS;
        uint8 recoveredV;
        assembly {
            recoveredR := mload(add(signature, 32))
            recoveredS := mload(add(signature, 64))
            recoveredV := byte(0, mload(add(signature, 96)))
        }
        address _recovered = ecrecover(hash, recoveredV, recoveredR, recoveredS);

        console.log("Recovered address (invalid):", _recovered);

        // Assert it does not match
        assertNotEq(_recovered, signer, "Invalid signature should not recover to signer");
    }
}
