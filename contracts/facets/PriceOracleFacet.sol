// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {LibPriceOracle} from "../libraries/LibPriceOracle.sol";
import {ADDRESS_NOT_WHITELISTED} from "../models/Error.sol";

/// @title PriceOracleFacet — Chainlink price-feed reads and Chainlink Functions oracle administration
contract PriceOracleFacet {
    using LibPriceOracle for LibAppStorage.StorageLayout;
    using FunctionsRequest for FunctionsRequest.Request;

    /// @notice Reads the latest Chainlink price for a token, reverting if the token is unsupported,
    ///         the answer is non-positive, or the round is stale.
    /// @param _token The token whose price feed is queried.
    /// @return Whether the returned price is considered stale (always false on success).
    /// @return The latest price answer in the feed's native decimals.
    function getPriceData(address _token) external view returns (bool, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getPriceData(_token);
    }

    /// @notice Computes the USD value of a token amount, normalized to 18-decimal precision.
    /// @param _token The token to value.
    /// @param _amount The token amount to convert.
    /// @return The latest price answer used in the conversion.
    /// @return The USD-equivalent value scaled to 18 decimals.
    function getTokenValueInUSD(address _token, uint256 _amount) external view returns (uint256, uint256) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s._getTokenValueInUSD(_token, _amount);
    }

    /// @notice Sets a per-token staleness threshold for its price feed; owner only.
    /// @param _token The token whose feed staleness threshold is updated.
    /// @param _threshold The maximum age in seconds before the feed is treated as stale (0 reverts to the default).
    function setPriceFeedStalenessThreshold(address _token, uint32 _threshold) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setPriceFeedStalenessThreshold(_token, _threshold);
    }

    /// @notice Initializes the Chainlink Functions oracle by setting the gas limit and configuring the router; owner only.
    /// @param _donID The Decentralized Oracle Network (DON) identifier.
    /// @param _router The Chainlink Functions router address.
    /// @param _linkToken The LINK token address used to pay for requests.
    /// @param _gasLimit The callback gas limit for fulfillment.
    /// @param _subscriptionId The Chainlink Functions subscription id to charge.
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
     * @param _linkToken The address of the LINK token used to pay for requests
     * @param _subscriptionId The Chainlink Functions subscription id to charge
     */
    function setupRouter(bytes32 _donID, address _router, address _linkToken, uint64 _subscriptionId) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setupRouter(_donID, _router, _linkToken, _subscriptionId);
    }

    /// @notice Stores the inline JavaScript source executed by the Chainlink Functions request; owner only.
    /// @param _source The JavaScript source code run by the DON when fulfilling price requests.
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
        // Refresh is keeper-triggered: only whitelisted keepers may bill the
        // protocol's LINK subscription, and the caller-supplied id is ignored in
        // favour of the protocol's own subscription so it can never be redirected.
        if (!s.isWhitelisted[msg.sender]) revert ADDRESS_NOT_WHITELISTED(msg.sender);
        subscriptionId = s.s_subscriptionId;

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

    /// @notice Approves and funds the protocol's Chainlink Functions subscription with LINK; owner only.
    /// @param _amount The amount of LINK to transfer into the subscription.
    function fundSubscription(uint96 _amount) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._fundSubscription(_amount);
    }

    /// @notice Sets the Chainlink Functions subscription id charged for requests; owner only.
    /// @param _subId The subscription id to store.
    function setSubscriptionId(uint64 _subId) external {
        LibDiamond.enforceIsContractOwner();
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        s._setSubscriptionId(_subId);
    }

    // Getter functions

    /// @notice Returns the currently configured Chainlink Functions subscription id.
    /// @return The stored subscription id.
    function getSubscriptionId() external view returns (uint64) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_subscriptionId;
    }

    /// @notice Returns the configured Chainlink Functions router address and DON id.
    /// @return The Chainlink Functions router address.
    /// @return The Decentralized Oracle Network (DON) identifier.
    function getRouterInfo() external view returns (address, bytes32) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return (s.s_router, s.s_donID);
    }

    /// @notice Returns the inline JavaScript source executed by Chainlink Functions requests.
    /// @return The stored JavaScript source code.
    function getSource() external view returns (string memory) {
        LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
        return s.s_source;
    }
}
