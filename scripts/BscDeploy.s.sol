// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/LiquidationFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/PriceOracleFacet.sol";
import "../contracts/facets/ProtocolFacet.sol";
import "../contracts/facets/PositionManagerFacet.sol";
import "../contracts/facets/VaultManagerFacet.sol";
import "../contracts/facets/YieldStrategyFacet.sol";
import "../contracts/facets/GettersFacet.sol";
import "../contracts/Diamond.sol";
import "../contracts/upgradeInitializers/DiamondInit.sol";

import {ONLY_SECURITY_COUNCIL} from "../contracts/models/Error.sol";

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

contract Aggregator is MockV3Aggregator {
    address public owner;

    constructor(address _owner, uint8 _decimals, int256 _initialAnswer) MockV3Aggregator(_decimals, _initialAnswer) {
        owner = _owner;
    }

    function updateAnswer(int256 _answer) public override onlyOwner {
        super.updateAnswer(_answer);
    }

    function updateRoundData(uint80 _roundId, int256 _answer, uint256 _timestamp, uint256 _startedAt)
        public
        override
        onlyOwner
    {
        super.updateRoundData(_roundId, _answer, _timestamp, _startedAt);
    }

    function _onlyOwner() internal view {
        // During parent constructor execution `owner` is not set yet (== address(0)).
        // Allow calls in that phase so MockV3Aggregator's constructor can set the
        // initial answer (it calls `updateAnswer` which is overridden here).
        if (owner == address(0)) return;
        if (msg.sender != owner) revert ONLY_SECURITY_COUNCIL();
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }
}

contract Deployment is Script, IDiamondCut {
    //contract types of facets to be deployed
    Diamond diamond;
    DiamondInit diamondInit;
    DiamondCutFacet dCutFacet;
    DiamondLoupeFacet dLoupe;
    OwnershipFacet ownerF;
    ProtocolFacet protocolF;
    PositionManagerFacet positionManagerF;
    VaultManagerFacet vaultManagerF;
    PriceOracleFacet priceOracleF;
    LiquidationFacet liquidationF;
    YieldStrategyFacet yieldStrategyF;
    GettersFacet gettersF;

    uint16 internal constant ALLOCATION_BPS = 4000; // 40%
    uint16 internal constant PROTOCOL_SHARE_BPS = 1500; // 15%

    address constant AAVE_POOL_ADDRESS = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5; // Aave V3 Base Pool

    // Test tokens
    address token1;
    address token2;
    address token3; // borrow token
    address token4;
    address token5;
    address token6;
    address pricefeed1;
    address pricefeed2;
    address pricefeed3; // borrow token pricefeed
    address pricefeed4;
    address pricefeed5;
    address pricefeed6;

    VaultConfiguration defaultConfig = VaultConfiguration({
        totalDeposits: 0,
        totalBorrows: 0,
        baseRate: 2000,
        slopeRate: 2500,
        reserveFactor: 1500,
        optimalUtilization: 7500,
        liquidationBonus: 500,
        lastUpdated: block.timestamp
    });

    function run() external {
        vm.startBroadcast();
        dCutFacet = new DiamondCutFacet();
        diamond = new Diamond(msg.sender, address(dCutFacet));
        diamondInit = new DiamondInit();
        dLoupe = new DiamondLoupeFacet();
        ownerF = new OwnershipFacet();
        protocolF = new ProtocolFacet();
        positionManagerF = new PositionManagerFacet();
        vaultManagerF = new VaultManagerFacet();
        priceOracleF = new PriceOracleFacet();
        liquidationF = new LiquidationFacet();
        // yieldStrategyF = new YieldStrategyFacet();
        gettersF = new GettersFacet();

        console.log("Deployed Addresses:");
        console.log("DiamondCutFacet: ", address(dCutFacet));
        console.log("Diamond: ", address(diamond));
        console.log("DiamondInit: ", address(diamondInit));
        console.log("DiamondLoupeFacet: ", address(dLoupe));
        console.log("OwnershipFacet: ", address(ownerF));
        console.log("ProtocolFacet: ", address(protocolF));
        console.log("PositionManagerFacet: ", address(positionManagerF));
        console.log("VaultManagerFacet: ", address(vaultManagerF));
        console.log("PriceOracleFacet: ", address(priceOracleF));
        console.log("LiquidationFacet: ", address(liquidationF));
        console.log("GettersFacet: ", address(gettersF));
        // console.log("YieldStrategyFacet: ", address(yieldStrategyF));

        //build cut struct
        FacetCut[] memory cut = new FacetCut[](8);

        cut[0] =
        (FacetCut({
                facetAddress: address(dLoupe),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("DiamondLoupeFacet")
            }));

        cut[1] =
        (FacetCut({
                facetAddress: address(ownerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("OwnershipFacet")
            }));

        cut[2] =
        (FacetCut({
                facetAddress: address(protocolF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("ProtocolFacet")
            }));

        cut[3] =
        (FacetCut({
                facetAddress: address(positionManagerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("PositionManagerFacet")
            }));

        cut[4] =
        (FacetCut({
                facetAddress: address(vaultManagerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("VaultManagerFacet")
            }));

        cut[5] =
        (FacetCut({
                facetAddress: address(priceOracleF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("PriceOracleFacet")
            }));

        cut[6] =
        (FacetCut({
                facetAddress: address(liquidationF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("LiquidationFacet")
            }));

        cut[7] =
        (FacetCut({
                facetAddress: address(gettersF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("GettersFacet")
            }));

        // cut[8] =
        // (FacetCut({
        //         facetAddress: address(yieldStrategyF),
        //         action: FacetCutAction.Add,
        //         functionSelectors: generateSelectors("YieldStrategyFacet")
        //     }));

        protocolF = ProtocolFacet(address(diamond));
        positionManagerF = PositionManagerFacet(address(diamond));
        vaultManagerF = VaultManagerFacet(address(diamond));
        ownerF = OwnershipFacet(address(diamond));
        priceOracleF = PriceOracleFacet(address(diamond));
        liquidationF = LiquidationFacet(address(diamond));
        // yieldStrategyF = YieldStrategyFacet(address(diamond));
        gettersF = GettersFacet(address(diamond));

        //upgrade diamond
        IDiamondCut(address(diamond)).diamondCut(cut, address(0x0), "");

        //call a function
        // DiamondLoupeFacet(address(diamond)).facetAddresses();

        Aggregator cngnPricefeed = new Aggregator(msg.sender, 8, 74371);
        console.log("Owner", cngnPricefeed.owner());
        cngnPricefeed.updateRoundData(18446744073709559735, 74371, 1771878051, 1771878051);

        console.log("CNGN Pricefeed", address(cngnPricefeed));

        token1 = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3; // DAI
        token2 = 0x404460C6A5EdE2D891e8297795264fDe62ADBB75; // LINK
        token3 = 0xa8AEA66B361a8d53e8865c62D142167Af28Af058; // CNGN
        token4 = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d; // USDC
        token5 = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8; // Binance-peg WETH
        token6 = address(1); //Native token placeholder
        // cngn = 0xa8AEA66B361a8d53e8865c62D142167Af28Af058;

        pricefeed1 = 0x132d3C0B1D2cEa0BC552588063bdBb210FDeecfA; // DAI/USD
        pricefeed2 = 0xca236E327F629f9Fc2c30A4E95775EbF0B89fac8; // LINK/USD
        pricefeed3 = address(cngnPricefeed); // CNGN/USD
        pricefeed4 = 0x51597f405303C4377E36123cBc172b13269EA163; // USDC/USD
        pricefeed5 = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e; // ETH/USD
        pricefeed6 = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE; // BNB/USD

        // cngnPriceFeed = 0x09f1458a15F8b0064450a8098D23443531fC6f95;

        // Setup initial collateral tokens
        _setupInitialCollateralAndBorrowTokens();
        protocolF.setInterestRate(2000, 500);
        positionManagerF.whitelistAddress(msg.sender);
        positionManagerF.createPositionFor(msg.sender);
        positionManagerF.setRequestBorrowSigner(msg.sender);

        // address vault = gettersF.getTokenVault(token3);
        // uint256 assets = gettersF.getVaultTotalAssets(token3);

        // console.log("CNGN Vault Address:", vault);
        // console.log("CNGN Vault Total Assets:", assets);

        ERC20Mock token = ERC20Mock(token3);
        uint256 balance = token.balanceOf(msg.sender);
        token.approve(address(diamond), balance);
        vaultManagerF.deposit(token3, balance);
        vm.stopBroadcast();
    }

    function _setupInitialCollateralAndBorrowTokens() internal {
        protocolF.addCollateralToken(token1, pricefeed1, 9000);
        protocolF.addCollateralToken(token2, pricefeed2, 8000);
        // protocolF.addCollateralToken(token3, pricefeed3, 7000);
        protocolF.addCollateralToken(token4, pricefeed4, 9000);
        protocolF.addCollateralToken(token5, pricefeed5, 8000);
        protocolF.addCollateralToken(token6, pricefeed6, 8000); // Native token

        vaultManagerF.deployVault(token3, pricefeed3, "Hodl CNGN", "HCNGN", defaultConfig);
    }

    function generateSelectors(string memory _facetName) internal returns (bytes4[] memory selectors) {
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "scripts/genSelectors.js";
        cmd[2] = _facetName;
        bytes memory res = vm.ffi(cmd);
        selectors = abi.decode(res, (bytes4[]));
    }

    function diamondCut(FacetCut[] calldata _diamondCut, address _init, bytes calldata _calldata) external override {}
}
