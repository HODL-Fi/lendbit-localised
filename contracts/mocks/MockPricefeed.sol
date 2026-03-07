// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {ReceiverTemplate} from "../interfaces/ReceiverTemplate.sol";
import {AggregatorV2V3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV2V3Interface.sol";

struct UpdatePricefeedRequest {
    string action;
    int256 amount;
    uint256 nonce;
    uint256 sourceChainId;
    uint256 targetChainId;
    address contractAddress;
}

error UNKNOWN_ACTION(string action);
error REQUEST_SIGNER_NOT_SET();
error REQUEST_INVALID_SIGNATURE(address recovered);
error REQUEST_NONCE_USED(address recovered, uint256 nonce);
error REQUEST_TARGET_CHAIN_MISMATCH(uint256 currentChainId, uint256 targetChainId);
error REQUEST_CONTRACT_MISMATCH(address currentContract, address targetContract);

contract Pricefeed is AggregatorV2V3Interface, ReceiverTemplate {
    uint256 public constant override version = 0;

    address requestSigner;

    uint8 public override decimals;
    int256 public override latestAnswer;
    uint256 public override latestTimestamp;
    uint256 public override latestRound;

    mapping(uint256 => int256) public override getAnswer;
    mapping(uint256 => uint256) public override getTimestamp;
    mapping(uint256 => uint256) private getStartedAt;

    mapping(address => mapping(uint256 => bool)) private requestRepayNonceUsed;

    constructor(uint8 _decimals, int256 _initialAnswer, address _requestSigner, address _forwarder)
        ReceiverTemplate(_forwarder)
    {
        decimals = _decimals;
        requestSigner = _requestSigner;
        _updateAnswer(_initialAnswer);
    }

    function updateAnswer(int256 _answer) public onlyOwner {
        _updateAnswer(_answer);
    }

    function _updateAnswer(int256 _answer) internal {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        latestRound++;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = block.timestamp;
        getStartedAt[latestRound] = block.timestamp;
    }

    function updateRoundData(uint80 _roundId, int256 _answer, uint256 _timestamp, uint256 _startedAt) public onlyOwner {
        latestRound = _roundId;
        latestAnswer = _answer;
        latestTimestamp = _timestamp;
        getAnswer[latestRound] = _answer;
        getTimestamp[latestRound] = _timestamp;
        getStartedAt[latestRound] = _startedAt;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, getAnswer[_roundId], getStartedAt[_roundId], getTimestamp[_roundId], _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (
            uint80(latestRound),
            getAnswer[latestRound],
            getStartedAt[latestRound],
            getTimestamp[latestRound],
            uint80(latestRound)
        );
    }

    function _processReport(bytes calldata report) internal override {
        (
            string memory action,
            int256 price,
            uint256 nonce,
            uint256 sourceChainId,
            uint256 targetChainId,
            address contractAddress
        ) = abi.decode(report, (string, int256, uint256, uint256, uint256, address));
        if (keccak256(bytes(action)) == keccak256(bytes("UPDATE_PRICEFEED"))) {
            UpdatePricefeedRequest memory _request = UpdatePricefeedRequest({
                action: action,
                amount: price,
                nonce: nonce,
                sourceChainId: sourceChainId,
                targetChainId: targetChainId,
                contractAddress: contractAddress
            });
            _verifyUpdatePricefeedRequest(_request);
            _updateAnswer(_request.amount);
        } else {
            revert UNKNOWN_ACTION(action);
        }
    }

    function _verifyUpdatePricefeedRequest(UpdatePricefeedRequest memory _request) internal view {
        if (requestSigner == address(0)) revert REQUEST_SIGNER_NOT_SET();

        if (_request.targetChainId != block.chainid) {
            revert REQUEST_TARGET_CHAIN_MISMATCH(block.chainid, _request.targetChainId);
        }

        if (_request.contractAddress != address(this)) {
            revert REQUEST_CONTRACT_MISMATCH(address(this), _request.contractAddress);
        }
    }

    function description() external pure override returns (string memory) {
        return "v0.8/tests/MockV3Aggregator.sol";
    }
}
