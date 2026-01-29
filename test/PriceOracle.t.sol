// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base, ERC20Mock} from "./Base.t.sol";
import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/PriceOracleFacet.sol";
import "../contracts/facets/ProtocolFacet.sol";
import "../contracts/Diamond.sol";

import "../contracts/models/Error.sol";
import "../contracts/models/Event.sol";

contract PriceOracleTest is Base {
    uint256 baseMainnetFork;
    uint256 baseSepoliaFork;

    uint64 subscriptionId = 438;
    address subOwner = 0xb159588fc04378B8334BA49593aAa3966663ACe1;
    // address linkHolder = 0x72bE417AFB0aBEa66913141C605D313BB389b59C; //mainnet
    address linkHolder = 0x4281eCF07378Ee595C564a59048801330f3084eE; //sepolia

    // address linkToken = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196; //mainnet
    address linkToken = 0xE4aB69C077896252FAFBD49EFD26B5D171A32410; //sepolia
    address baseRouter = 0xf9B8fc078197181C841c296C876945aaa425B278;
    // bytes32 baseDonId = 0x66756e2d626173652d6d61696e6e65742d310000000000000000000000000000;
    bytes32 baseDonId = 0x66756e2d626173652d7365706f6c69612d310000000000000000000000000000;
    string source = "const stableCoin = args[0]" "const localCurrency = args[1]"
        "const apiResponse = await Functions.makeHttpRequest({"
        "url: `https://api.paycrest.io/v1/rates/${stableCoin}/100/${localCurrency}`,"
        "headers: {'API-Key': secrets.apiKey}" "})" "if (apiResponse.error) {" "console.error(apiResponse.error)"
        "throw Error('Request failed')" "}" "const { data } = apiResponse;" "return Functions.encodeString(data.data)";

    function setUp() public override {
        // baseMainnetFork = vm.createFork(vm.envString("BASE_MAINNET_URL"));
        // baseSepoliaFork = vm.createFork(vm.envString("BASE_SEPOLIA_URL"));
        // vm.selectFork(baseSepoliaFork);

        super.setUp();

        // priceOracleF.initializePriceOracle(baseDonId, baseRouter, linkToken, 300000, subscriptionId);
        // priceOracleF.setupSource(source);
        // addContractAsConsumer();
    }

    function testGetPriceData() public view {
        (bool _isStale, uint256 _price) = priceOracleF.getPriceData(address(token1));
        assertFalse(_isStale);
        assertEq(_price, 1500 * 1e8);
    }

    function testGetTokenValueInUSD() public view {
        uint256 _amount = 1000 * 1e18;

        (, uint256 _tokenValue) = priceOracleF.getTokenValueInUSD(address(token1), _amount);
        assertEq(_tokenValue, (_amount * 1500));
    }

    function testGetPriceDataFailForUnsupportedTokens() public {
        address _token = address(0xdead);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, _token));
        priceOracleF.getPriceData(_token);
    }

    function testGetTokenValueInUSDForDifferentDecimals() public {
        protocolF.addCollateralToken(address(token3), pricefeed3, baseTokenLTV);
        uint256 _amount = 1000 * 1e6; // token2 has 6 decimals

        // Test with token2 which has 6 decimals and price $1
        uint256 expectedValue = (_amount * 1e12); // Should be normalized to 18 decimals
        (, uint256 actualValue) = priceOracleF.getTokenValueInUSD(address(token3), _amount);
        assertEq(actualValue, expectedValue, "Token3 USD value should be normalized correctly");
    }

    function testGetTokenValueInUSDFailsForUnsupportedToken() public {
        uint256 amount = 1000 * 1e18;

        // Deploy a new token that doesn't have a price feed
        ERC20Mock newToken = new ERC20Mock(18);

        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(newToken)));
        priceOracleF.getTokenValueInUSD(address(newToken), amount);
    }

    function testGetTokenValueInUSDWithZeroAmount() public view {
        uint256 _amount = 0;

        // Should return 0 for zero amount regardless of price feed
        (, uint256 _value) = priceOracleF.getTokenValueInUSD(address(token1), _amount);
        assertEq(_value, 0);
    }

    // function testInitialization() public view {
    //     uint64 _subId = priceOracleF.getSubscriptionId();
    //     (address _router, bytes32 _donId) = priceOracleF.getRouterInfo();
    //     assertEq(_subId, subscriptionId);
    //     assertEq(_router, baseRouter);
    //     assertEq(_donId, baseDonId);
    // }

    // function testSetupSource() public {
    //     string memory _source = "const stableCoin = args[0]" "const localCurrency = args[1]"
    //         "const apiResponse = await Functions.makeHttpRequest({"
    //         "url: `https://api.paycrest.io/v1/rates/${stableCoin}/100/${localCurrency}`,"
    //         "headers: {'API-Key': secrets.apiKey}" "})" "if (apiResponse.error) {" "console.error(apiResponse.error)"
    //         "throw Error('Request failed')" "}" "const { data } = apiResponse;"
    //         "return Functions.encodeUint256(data.data * (10**8))";
    //     vm.expectEmit(true, true, true, true);
    //     emit FunctionsSourceChanged(address(this), abi.encode(_source));
    //     priceOracleF.setupSource(_source);

    //     string memory returnedSource = priceOracleF.getSource();
    //     assertEq(returnedSource, _source);
    // }

    // function testRequestPrice() public {
    //     string[] memory args = new string[](2);
    //     args[0] = "USDT";
    //     args[1] = "NGN";
    //     //request character info
    //     bytes32 reqId = priceOracleF.sendRequest(subscriptionId, args);
    //     assertTrue(reqId != 0);

    //     vm.warp(block.timestamp + 1 minutes);

    //     // (FunctionsResponse.FulfillResult _callbackResult, uint96 _callbackCost) = IFunctionsRouter(baseRouter).fulfill(
    //     //     abi.encode(150000000000),
    //     //     bytes(""),
    //     //     1000000000,
    //     //     0,
    //     //     address(this),
    //     //     FunctionsResponse.Commitment({
    //     //         requestId: reqId,
    //     //         coordinator: address(0),
    //     //         estimatedTotalCostJuels: 0,
    //     //         client: address(priceOracleF),
    //     //         subscriptionId: subscriptionId,
    //     //         callbackGasLimit: 300000,
    //     //         adminFee: 0,
    //     //         donFee: 0,
    //     //         gasOverheadBeforeCallback: 0,
    //     //         gasOverheadAfterCallback: 0,
    //     //         timeoutTimestamp: uint32(block.timestamp + 5 minutes)
    //     //     })
    //     // );
    // }

    // function addContractAsConsumer() internal {
    //     vm.startPrank(subOwner);
    //     IFunctionsSubscriptions(baseRouter).addConsumer(subscriptionId, address(diamond));
    //     vm.stopPrank();
    // }

    function addCollateralTokens() internal {
        protocolF.addCollateralToken(address(token1), pricefeed1, baseTokenLTV);
        protocolF.addCollateralToken(address(token2), pricefeed2, baseTokenLTV);
    }

    function deployPriceFeed() internal {
        (address _token1, address _pricefeed1) = deployERC20ContractAndAddPriceFeed("token1", 18, 2000);
        (address _token2, address _pricefeed2) = deployERC20ContractAndAddPriceFeed("token2", 6, 1);

        token1 = ERC20Mock(_token1);
        token2 = ERC20Mock(_token2);

        pricefeed1 = _pricefeed1;
        pricefeed2 = _pricefeed2;
    }
}
