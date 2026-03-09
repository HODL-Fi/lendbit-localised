// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPriceOracle} from "../libraries/LibPriceOracle.sol";

contract PriceOracleFacet {
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using FunctionsRequest for FunctionsRequest.Request;

    function getPriceData(address _token) external view returns (bool, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPriceData(_token);
    }

    function getTokenValueInUSD(address _token, uint256 _amount) external view returns (uint256, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getTokenValueInUSD(_token, _amount);
    }

    function initializePriceOracle(
        bytes32 _donID,
        address _router,
        address _linkToken,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._initializePriceOracle(_donID, _router, _linkToken, _gasLimit, _subscriptionId);
    }

    /**
     * @notice setup the Chainlink router address and sets the DON ID
     * @param _donID The ID of the Decentralized Oracle Network (DON)
     * @param _router The address of the Chainlink Functions router contract
     */
    function setupRouter(bytes32 _donID, address _router, address _linkToken, uint64 _subscriptionId) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setupRouter(_donID, _router, _linkToken, _subscriptionId);
    }

    function setupSource(string calldata _source) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setupSource(_source);
    }

    /**
     * @notice Sends an HTTP request for character information
     * @param subscriptionId The ID for the Chainlink subscription
     * @param args The arguments to pass to the HTTP request
     * @return requestId The ID of the request
     */
    function sendRequest(uint64 subscriptionId, string[] calldata args) external returns (bytes32 requestId) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(s.s_source); // Initialize the request with JS code
        if (args.length > 0) req.setArgs(args); // Set the arguments for the request

        // Send the request and store the request ID
        bytes32 s_lastRequestId = s._sendRequest(req.encodeCBOR(), subscriptionId, s.s_gasLimit, s.s_donID);

        return s_lastRequestId;
    }

    /**
     * @notice Callback function for fulfilling a request
     * @param _requestId The ID of the request to fulfill
     * @param _response The HTTP response data
     * @param _err Any errors from the Functions request
     */
    function handleOracleFulfillment(bytes32 _requestId, bytes memory _response, bytes memory _err) external {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._handleOracleFulfillment(_requestId, _response, _err);
    }

    function fundSubscription(uint96 _amount) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._fundSubscription(_amount);
    }

    function setSubscriptionId(uint64 _subId) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setSubscriptionId(_subId);
    }

    // Getter functions

    function getSubscriptionId() external view returns (uint64) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_subscriptionId;
    }

    function getRouterInfo() external view returns (address, bytes32) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return (s.s_router, s.s_donID);
    }

    function getSource() external view returns (string memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_source;
    }
}
