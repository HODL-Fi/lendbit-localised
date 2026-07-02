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

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

contract Deployment is Script, IDiamondCut {
    //contract types of facets to be deployed
    Diamond diamond;
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
        baseRate: 500,
        slopeRate: 1500,
        reserveFactor: 2000,
        optimalUtilization: 7500,
        liquidationBonus: 1000,
        lastUpdated: block.timestamp
    });

    function run() external {
        vm.startBroadcast();
        //deploy facets
        dCutFacet = new DiamondCutFacet();
        diamond = new Diamond(msg.sender, address(dCutFacet));
        dLoupe = new DiamondLoupeFacet();
        ownerF = new OwnershipFacet();
        protocolF = new ProtocolFacet();
        positionManagerF = new PositionManagerFacet();
        vaultManagerF = new VaultManagerFacet();
        priceOracleF = new PriceOracleFacet();
        liquidationF = new LiquidationFacet();
        yieldStrategyF = new YieldStrategyFacet();
        gettersF = new GettersFacet();

        console.log("Deployed Addresses:");
        console.log("DiamondCutFacet: ", address(dCutFacet));
        console.log("Diamond: ", address(diamond));
        console.log("DiamondLoupeFacet: ", address(dLoupe));
        console.log("OwnershipFacet: ", address(ownerF));
        console.log("ProtocolFacet: ", address(protocolF));
        console.log("PositionManagerFacet: ", address(positionManagerF));
        console.log("VaultManagerFacet: ", address(vaultManagerF));
        console.log("PriceOracleFacet: ", address(priceOracleF));
        console.log("LiquidationFacet: ", address(liquidationF));   

        //upgrade diamond with facets
        //build cut struct
        FacetCut[] memory cut = new FacetCut[](9);

        cut[0] = (
            FacetCut({
                facetAddress: address(dLoupe),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("DiamondLoupeFacet")
            })
        );

        cut[1] = (
            FacetCut({
                facetAddress: address(ownerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("OwnershipFacet")
            })
        );

        cut[2] = (
            FacetCut({
                facetAddress: address(protocolF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("ProtocolFacet")
            })
        );

        cut[3] = (
            FacetCut({
                facetAddress: address(positionManagerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("PositionManagerFacet")
            })
        );

        cut[4] = (
            FacetCut({
                facetAddress: address(vaultManagerF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("VaultManagerFacet")
            })
        );

        cut[5] = (
            FacetCut({
                facetAddress: address(priceOracleF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("PriceOracleFacet")
            })
        );

        cut[6] = (
            FacetCut({
                facetAddress: address(liquidationF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("LiquidationFacet")
            })
        );

        cut[7] = (
            FacetCut({
                facetAddress: address(yieldStrategyF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("YieldStrategyFacet")
            })
        );

        cut[8] = (
            FacetCut({
                facetAddress: address(gettersF),
                action: FacetCutAction.Add,
                functionSelectors: generateSelectors("GettersFacet")
            })
        );

        protocolF = ProtocolFacet(address(diamond));
        positionManagerF = PositionManagerFacet(address(diamond));
        vaultManagerF = VaultManagerFacet(address(diamond));
        priceOracleF = PriceOracleFacet(address(diamond));
        liquidationF = LiquidationFacet(address(diamond));
        yieldStrategyF = YieldStrategyFacet(address(diamond));
        gettersF = GettersFacet(address(diamond));

        //upgrade diamond
        IDiamondCut(address(diamond)).diamondCut(cut, address(0x0), "");

        //call a function
        DiamondLoupeFacet(address(diamond)).facetAddresses();

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

        // Setup initial collateral tokens
        _setupInitialCollateralAndBorrowTokens();
        // 27.78% APR with the 20% reserveFactor yields ~20% LP / ~5% protocol on
        // deposited capital at the 90% utilization cap (MAX_UTILIZATION). The pool
        // can't reach 100% utilization, so the APR is grossed up by 1/0.9 to let
        // LPs still realize 20% on their deposit.
        protocolF.setInterestRate(2778, 500);

        // The deployer must be whitelisted before it can own a position —
        // `createPositionFor` reverts ADDRESS_NOT_WHITELISTED otherwise, which would
        // abort the whole deploy (see lead: deployer not whitelisted before
        // createPositionFor).
        positionManagerF.whitelistAddress(msg.sender);
        positionManagerF.createPositionFor(msg.sender);
        ERC20Mock(token3).mint(msg.sender, 500000e6); // mint 500000 CNGN to msg.sender
        ERC20Mock(token3).approve(address(diamond), 500000e6);
        protocolF.depositCollateral(token3, 500000e6);
        vm.stopBroadcast();

        console.log("MOCK CNGN: ", token3);
        console.log("MOCK CNGN/USD: ", pricefeed3);
    }

    function _setupInitialCollateralAndBorrowTokens() internal {
        protocolF.addCollateralToken(token1, pricefeed1, 8000);
        protocolF.addCollateralToken(token2, pricefeed2, 8000);
        protocolF.addCollateralToken(token3, pricefeed3, 7000);
        protocolF.addCollateralToken(token4, pricefeed4, 8000);

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
