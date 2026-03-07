// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibProtocol} from "../libraries/LibProtocol.sol";

import "../models/Error.sol";
import "../models/Event.sol";

import {RepayRequest} from "../models/Protocol.sol";

contract ReceiverFacet {
    using LibProtocol for LibAppStorage.StorageLayout;

    /// @dev Performs optional validation checks based on which permission fields are set
    function onReport(bytes calldata metadata, bytes calldata report) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        // Security Check 1: Verify caller is the trusted Chainlink Forwarder (if configured)
        if (s.s_forwarderAddress != address(0) && msg.sender != s.s_forwarderAddress) {
            revert InvalidSender(msg.sender, s.s_forwarderAddress);
        }

        // Security Checks 2-4: Verify workflow identity - ID, owner, and/or name (if any are configured)
        if (
            s.s_expectedWorkflowId != bytes32(0) || s.s_expectedAuthor != address(0)
                || s.s_expectedWorkflowName != bytes10(0)
        ) {
            (bytes32 workflowId, bytes10 workflowName, address workflowOwner) = _decodeMetadata(metadata);

            if (s.s_expectedWorkflowId != bytes32(0) && workflowId != s.s_expectedWorkflowId) {
                revert InvalidWorkflowId(workflowId, s.s_expectedWorkflowId);
            }
            if (s.s_expectedAuthor != address(0) && workflowOwner != s.s_expectedAuthor) {
                revert InvalidAuthor(workflowOwner, s.s_expectedAuthor);
            }

            // ================================================================
            // WORKFLOW NAME VALIDATION - REQUIRES AUTHOR VALIDATION
            // ================================================================
            // Do not rely on workflow name validation alone. Workflow names are unique
            // per owner, but not across owners.
            // Furthermore, workflow names use 40-bit truncation (bytes10), making collisions possible.
            // Therefore, workflow name validation REQUIRES author (workflow owner) validation.
            // The code enforces this dependency at runtime.
            // ================================================================
            if (s.s_expectedWorkflowName != bytes10(0)) {
                // Author must be configured if workflow name is used
                if (s.s_expectedAuthor == address(0)) {
                    revert WorkflowNameRequiresAuthorValidation();
                }
                // Validate workflow name matches (author already validated above)
                if (workflowName != s.s_expectedWorkflowName) {
                    revert InvalidWorkflowName(workflowName, s.s_expectedWorkflowName);
                }
            }
        }

        _processReport(report);
    }

    /// @dev Routes to either lending debt creation based on prefix byte.
    function _processReport(bytes calldata report) internal {
        if (report.length > 0 && report[0] == 0x02) {
            _handleRepayCreation(report[1:]);
        }
    }

    function _handleRepayCreation(bytes calldata reportData) internal {
        (
            string memory action,
            uint256 loanId,
            uint256 amount,
            uint256 sourceChainId,
            uint256 targetChainId,
            uint256 nonce,
            address contractAddress,
            address walletAddress,
            bytes memory _signature
        ) = abi.decode(reportData, (string, uint256, uint256, uint256, uint256, uint256, address, address, bytes));

        RepayRequest memory _request = RepayRequest({
            action: action,
            loanId: loanId,
            amount: amount,
            sourceChainId: sourceChainId,
            targetChainId: targetChainId,
            nonce: nonce,
            contractAddress: contractAddress,
            walletAddress: walletAddress
        });
        if (keccak256(bytes(action)) == keccak256(bytes("repay"))) {
            LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
            s._repayLoan(_request, _signature);
        } else {
            revert InvalidAction(action);
        }
    }

    //Helpers
    /// @notice Extracts all metadata fields from the onReport metadata parameter
    /// @param metadata The metadata bytes encoded using abi.encodePacked(workflowId, workflowName, workflowOwner)
    /// @return workflowId The unique identifier of the workflow (bytes32)
    /// @return workflowName The name of the workflow (bytes10)
    /// @return workflowOwner The owner address of the workflow
    function _decodeMetadata(bytes memory metadata)
        internal
        pure
        returns (bytes32 workflowId, bytes10 workflowName, address workflowOwner)
    {
        // Metadata structure (encoded using abi.encodePacked by the Forwarder):
        // - First 32 bytes: length of the byte array (standard for dynamic bytes)
        // - Offset 32, size 32: workflow_id (bytes32)
        // - Offset 64, size 10: workflow_name (bytes10)
        // - Offset 74, size 20: workflow_owner (address)
        assembly {
            workflowId := mload(add(metadata, 32))
            workflowName := mload(add(metadata, 64))
            workflowOwner := shr(mul(12, 8), mload(add(metadata, 74)))
        }
        return (workflowId, workflowName, workflowOwner);
    }
}
