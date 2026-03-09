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
import "../contracts/facets/ReceiverFacet.sol";
import "../contracts/Diamond.sol";
import "../contracts/upgradeInitializers/DiamondInit.sol";

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

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
    ReceiverFacet receiverF;

    uint16 internal constant ALLOCATION_BPS = 4000; // 40%
    uint16 internal constant PROTOCOL_SHARE_BPS = 1500; // 15%

    address constant AAVE_POOL_ADDRESS = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5; // Aave V3 Base Pool

    // Test tokens
    address token1;
    address token2;
    address token3; // borrow token
    address token4;
    address token5;
    address pricefeed1;
    address pricefeed2;
    address pricefeed3; // borrow token pricefeed
    address pricefeed4;
    address pricefeed5;

    VaultConfiguration defaultConfig = VaultConfiguration({
        totalDeposits: 0,
        totalBorrows: 0,
        baseRate: 2000,
        slopeRate: 2500,
        reserveFactor: 2000,
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
        yieldStrategyF = new YieldStrategyFacet();
        gettersF = new GettersFacet();
        receiverF = new ReceiverFacet();

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
        console.log("YieldStrategyFacet: ", address(yieldStrategyF));
        console.log("ReceiverFacet: ", address(receiverF));

        //build cut struct
        FacetCut[] memory cut = new FacetCut[](10);

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

        cut[8] =
        (FacetCut({
                facetAddress: address(yieldStrategyF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("YieldStrategyFacet")
            }));
        cut[9] =
        (FacetCut({
                facetAddress: address(receiverF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("ReceiverFacet")
            }));

        protocolF = ProtocolFacet(address(diamond));
        positionManagerF = PositionManagerFacet(address(diamond));
        vaultManagerF = VaultManagerFacet(address(diamond));
        ownerF = OwnershipFacet(address(diamond));
        priceOracleF = PriceOracleFacet(address(diamond));
        liquidationF = LiquidationFacet(address(diamond));
        // yieldStrategyF = YieldStrategyFacet(address(diamond));
        gettersF = GettersFacet(address(diamond));
        receiverF = ReceiverFacet(address(diamond));

        //upgrade diamond
        IDiamondCut(address(diamond)).diamondCut(cut, address(0x0), "");

        //call a function
        // DiamondLoupeFacet(address(diamond)).facetAddresses();

        token1 = 0xFaEc9cDC3Ef75713b48f46057B98BA04885e3391; // EURC
        token2 = 0xb2b2130b4B83Af141cFc4C5E3dEB1897eB336D79; // LINK
        token3 = 0xc4e08f4e2E50efF89B476c9416F0B7B607EDB71a; // address(new ERC20Mock(6)); // CNGN
        token4 = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // USDC
        token5 = address(1); //Native token placeholder

        pricefeed1 = 0xD1092a65338d049DB68D7Be6bD89d17a0929945e; // DAI/USD
        pricefeed2 = 0xb113F5A928BCfF189C998ab20d753a47F9dE5A61; // LINK/USD
        pricefeed3 = 0xe73b80A97C77982Fc2C99F47A5b4e3Be5463E084; // address(new MockV3Aggregator(8, 1500e8)); // CNGN/USD
        pricefeed4 = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165; // USDC/USD
        pricefeed5 = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1; // ETH/USD

        // use recent NGN/USD rate
        MockV3Aggregator(0xe73b80A97C77982Fc2C99F47A5b4e3Be5463E084).updateAnswer(72000);

        // token1 = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb; // DAI
        // token2 = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196; // LINK
        // token3 = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F; // CNGN
        // token4 = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // USDC
        // token5 = address(1); //Native token placeholder
        // cngn = 0x46C85152bFe9f96829aA94755D9f915F9B10EF5F;

        // pricefeed1 = 0x591e79239a7d679378eC8c847e5038150364C78F; // DAI/USD
        // pricefeed2 = 0x17CAb8FE31E32f08326e5E27412894e49B0f9D65; // LINK/USD
        // pricefeed3 = 0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD; // CNGN/USD
        // pricefeed4 = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B; // USDC/USD
        // pricefeed5 = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70; // ETH/USD

        // Setup initial collateral tokens
        _setupInitialCollateralAndBorrowTokens();
        protocolF.setInterestRate(2000, 500);
        positionManagerF.setForwarderAddress(0xF8344CFd5c43616a4366C34E3EEE75af79a74482);
        positionManagerF.whitelistAddress(msg.sender);
        positionManagerF.createPositionFor(msg.sender);
        positionManagerF.setRequestBorrowSigner(0xb159588fc04378B8334BA49593aAa3966663ACe1);

        ERC20Mock cngn = ERC20Mock(token3);
        uint256 amount = 500_000_000e6;
        cngn.mint(msg.sender, amount);
        cngn.approve(address(diamond), amount);
        vaultManagerF.deposit(token3, amount);
        vm.stopBroadcast();
    }

    function _setupInitialCollateralAndBorrowTokens() internal {
        protocolF.addCollateralToken(token1, pricefeed1, 9000);
        protocolF.addCollateralToken(token2, pricefeed2, 8000);
        protocolF.addCollateralToken(token4, pricefeed4, 9000);
        protocolF.addCollateralToken(token5, pricefeed5, 8000); // Native token

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
