// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFunctionsRouter} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/interfaces/IFunctionsRouter.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {LibAppStorage} from "./LibAppStorage.sol";
import {LibUtils} from "./LibUtils.sol";

import {
    OnlyRouterCanFulfill,
    UnexpectedRequestID,
    TOKEN_NOT_SUPPORTED,
    STALE_PRICE_FEED,
    INVALID_PRICE_FEED
} from "../models/Error.sol";
import {
    Response,
    RequestSent,
    RequestFulfilled,
    FunctionsRouterChanged,
    FunctionsSourceChanged
} from "../models/Event.sol";
import {FunctionResponse} from "../models/Protocol.sol";

import {Constants} from "../models/Constant.sol";

/// @title The Chainlink Functions client contract converted into a library for the PriceOracleFacet
library LibPriceOracle {
    using FunctionsRequest for FunctionsRequest.Request;

    /// @notice Reads the latest Chainlink price for `_token`, reverting on an unsupported token, non-positive answer, mismatched round, or stale update.
    /// @param _token The token whose configured price feed is read.
    /// @return A staleness flag (always false on success) and the latest price answer in feed decimals.
    function _getPriceData(LibAppStorage.StorageLayout storage s, address _token)
        internal
        view
        returns (bool, uint256)
    {
        address _pricefeed = s.s_tokenPriceFeed[_token];
        if (_pricefeed == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        (uint80 _roundId, int256 _answer,, uint256 _updatedAt, uint80 _answeredInRound) =
            AggregatorV3Interface(_pricefeed).latestRoundData();

        if (_answer <= 0) revert INVALID_PRICE_FEED(_pricefeed);

        if (_roundId != _answeredInRound) revert STALE_PRICE_FEED(_pricefeed);

        uint32 _threshold = s.s_priceFeedStalenessThreshold[_token];
        if (_threshold == 0) _threshold = Constants.DEFAULT_STALENESS_THRESHOLD;
        if (block.timestamp - _updatedAt > _threshold) revert STALE_PRICE_FEED(_pricefeed);

        // `_answer` is guarded `> 0` above, so the int256->uint256 cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (false, uint256(_answer));
    }

    /// @notice Sets a custom staleness threshold for a specific token's price feed.
    /// @dev Pass 0 to revert to the protocol-wide DEFAULT_STALENESS_THRESHOLD.
    ///      Typical values: 3600 (1 h) for high-frequency feeds, 86400 (24 h) for low-frequency feeds.
    function _setPriceFeedStalenessThreshold(LibAppStorage.StorageLayout storage s, address _token, uint32 _threshold)
        internal
    {
        s.s_priceFeedStalenessThreshold[_token] = _threshold;
    }

    /// @notice Returns the decimal precision of `_token`'s configured price feed, reverting if the token is unsupported.
    /// @param _token The token whose price feed decimals are queried.
    /// @return The price feed's decimals.
    function _getPriceDecimals(LibAppStorage.StorageLayout storage s, address _token) internal view returns (uint8) {
        address _pricefeed = s.s_tokenPriceFeed[_token];
        if (_pricefeed == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        return AggregatorV3Interface(_pricefeed).decimals();
    }

    /// @notice Computes the USD value of `_amount` of `_token` using its price feed, returning (0, 0) for a zero amount.
    /// @param _token The token to value.
    /// @param _amount The token amount in the token's native decimals.
    /// @return The feed price and the corresponding USD value.
    function _getTokenValueInUSD(LibAppStorage.StorageLayout storage s, address _token, uint256 _amount)
        internal
        view
        returns (uint256, uint256)
    {
        if (_amount == 0) return (0, 0);

        (bool _isStale, uint256 _price) = _getPriceData(s, _token);
        if (_isStale) revert STALE_PRICE_FEED(_token);
        if (_price <= 0) revert INVALID_PRICE_FEED(_token);

        // Normalize to 18 decimals
        uint8 _decimals = LibUtils._getTokenDecimals(_token);
        uint8 _feedDecimals = _getPriceDecimals(s, _token);
        uint256 _usdValue = _calculateTokenUSDEquivalent(_decimals, _feedDecimals, _price, _amount);

        return (_price, _usdValue);
    }

    /// @notice Scales `_price` up to 18 decimals and multiplies by `_amount` to produce the USD value of the token amount.
    /// @param _decimals The token's decimals.
    /// @param _feedDecimals The price feed's decimals.
    /// @param _price The feed price in `_feedDecimals`.
    /// @param _amount The token amount in `_decimals`.
    /// @return _usdValue The USD value (0 when `_amount` is 0).
    function _calculateTokenUSDEquivalent(uint8 _decimals, uint8 _feedDecimals, uint256 _price, uint256 _amount)
        internal
        pure
        returns (uint256 _usdValue)
    {
        if (_amount == 0) return _usdValue;

        // Scale the feed price up from its native decimals to PRECISION_SCALE (18)
        uint256 scaledPrice = _price * (10 ** (Constants.PRECISION_SCALE - _feedDecimals));
        _usdValue = (scaledPrice * _amount) / (10 ** _decimals);
    }

    /// @notice Sets the Chainlink Functions gas limit and wires up the router, LINK token, DON ID, and subscription.
    /// @param _donID The DON identifier.
    /// @param _router The Functions router address.
    /// @param _linkToken The LINK token address.
    /// @param _gasLimit The callback gas limit.
    /// @param _subscriptionId The Functions subscription ID.
    function _initializePriceOracle(
        LibAppStorage.StorageLayout storage s,
        bytes32 _donID,
        address _router,
        address _linkToken,
        uint32 _gasLimit,
        uint64 _subscriptionId
    ) internal {
        s.s_gasLimit = _gasLimit;
        _setupRouter(s, _donID, _router, _linkToken, _subscriptionId);
    }

    /// @notice Stores the DON ID, router, LINK token, and subscription ID, then emits FunctionsRouterChanged.
    /// @param _donID The DON identifier.
    /// @param _router The Functions router address.
    /// @param _linkToken The LINK token address.
    /// @param _subscriptionId The Functions subscription ID.
    function _setupRouter(
        LibAppStorage.StorageLayout storage s,
        bytes32 _donID,
        address _router,
        address _linkToken,
        uint64 _subscriptionId
    ) internal {
        s.s_donID = _donID;
        s.s_router = _router;
        s.i_router = IFunctionsRouter(_router);
        s.i_linkToken = LinkTokenInterface(_linkToken);
        s.s_subscriptionId = _subscriptionId;
        emit FunctionsRouterChanged(msg.sender, _donID, _router);
    }

    /// @notice Stores the JavaScript source executed by Chainlink Functions and emits FunctionsSourceChanged.
    /// @param _source The Functions request source code.
    function _setupSource(LibAppStorage.StorageLayout storage s, string calldata _source) internal {
        s.s_source = _source;
        emit FunctionsSourceChanged(msg.sender, abi.encode(_source));
    }

    /// @notice Sends a Chainlink Functions request
    /// @param data The CBOR encoded bytes data for a Functions request
    /// @param subscriptionId The subscription ID that will be charged to service the request
    /// @param callbackGasLimit the amount of gas that will be available for the fulfillment callback
    /// @return requestId The generated request ID for this request
    function _sendRequest(
        LibAppStorage.StorageLayout storage s,
        bytes memory data,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        bytes32 donId
    ) internal returns (bytes32) {
        bytes32 _requestId = s.i_router
            .sendRequest(subscriptionId, data, FunctionsRequest.REQUEST_DATA_VERSION, callbackGasLimit, donId);
        s.s_functionResponse[_requestId] =
            FunctionResponse({requestId: _requestId, responses: "", err: "", priceData: 0, exists: true});
        emit RequestSent(_requestId);
        return _requestId;
    }

    /// @notice User defined function to handle a response from the DON
    /// @param _requestId The request ID, returned by sendRequest()
    /// @param _response Aggregated response from the execution of the user's source code
    /// @param _err Aggregated error from the execution of the user code or from the execution pipeline
    /// @dev Either response or error parameter will be set, but never both
    function _fulfillRequest(
        LibAppStorage.StorageLayout storage s,
        bytes32 _requestId,
        bytes memory _response,
        bytes memory _err
    ) internal {
        FunctionResponse storage res = s.s_functionResponse[_requestId];
        if (!res.exists) {
            revert UnexpectedRequestID(_requestId); // Check if request IDs match
        }
        // Update the contract's state variables with the response and any errors
        res.responses = _response;
        (res.priceData) = abi.decode(_response, (uint256));
        res.err = _err;

        // Emit an event to log the response
        emit Response(_requestId, res.priceData, _response, _err);
    }

    /// @notice Router-gated entry that fulfills `requestId` with the DON response and emits RequestFulfilled.
    /// @param requestId The request ID being fulfilled.
    /// @param response The aggregated DON response.
    /// @param err The aggregated DON error.
    /// @dev Reverts with OnlyRouterCanFulfill unless the caller is the configured Functions router.
    function _handleOracleFulfillment(
        LibAppStorage.StorageLayout storage s,
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal {
        if (msg.sender != address(s.i_router)) {
            revert OnlyRouterCanFulfill();
        }
        _fulfillRequest(s, requestId, response, err);
        emit RequestFulfilled(requestId);
    }

    /// @notice Approves the router for `_amount` of LINK and funds the configured subscription via transferAndCall.
    /// @param _amount The LINK amount to fund the subscription with.
    function _fundSubscription(LibAppStorage.StorageLayout storage s, uint256 _amount) internal {
        // Approve the router to spend the specified amount of LINK
        s.i_linkToken.approve(address(s.i_router), _amount);
        // Fund the subscription
        s.i_linkToken
            .transferAndCall(
                address(s.i_router),
                _amount,
                abi.encode(s.s_subscriptionId) // Encode the subscription ID in the data field
            );
    }

    /// @notice Updates the stored Chainlink Functions subscription ID.
    /// @param _subId The new subscription ID.
    function _setSubscriptionId(LibAppStorage.StorageLayout storage s, uint64 _subId) internal {
        s.s_subscriptionId = _subId;
    }
}
