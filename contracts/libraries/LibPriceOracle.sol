// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

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

    function _getPriceData(LibAppStorage.StorageLayout storage s, address _token)
        internal
        view
        returns (bool, uint256)
    {
        address _pricefeed = s.s_tokenPriceFeed[_token];
        if (_pricefeed == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        (uint80 _roundId, int256 _answer,,, uint80 _answeredInRound) =
            AggregatorV3Interface(_pricefeed).latestRoundData();

        bool _isStale = (_roundId != _answeredInRound);
        return (_isStale, uint256(_answer));
    }

    function _getPriceDecimals(LibAppStorage.StorageLayout storage s, address _token) internal view returns (uint8) {
        address _pricefeed = s.s_tokenPriceFeed[_token];
        if (_pricefeed == address(0)) revert TOKEN_NOT_SUPPORTED(_token);

        return AggregatorV3Interface(_pricefeed).decimals();
    }

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
        uint256 _usdValue = _calculateTokenUSDEquivalent(_decimals, _price, _amount);

        return (_price, _usdValue);
    }

    function _calculateTokenUSDEquivalent(uint8 _decimals, uint256 _price, uint256 _amount)
        internal
        pure
        returns (uint256 _usdValue)
    {
        if (_amount == 0) return _usdValue;

        uint256 scaledPrice = _price * (10 ** (Constants.PRECISION_SCALE - 8)); // e.g., 1e10 if PRECISION is 1e18
        _usdValue = (scaledPrice * _amount) / (10 ** _decimals);
    }

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

    function _setSubscriptionId(LibAppStorage.StorageLayout storage s, uint64 _subId) internal {
        s.s_subscriptionId = _subId;
    }
}
