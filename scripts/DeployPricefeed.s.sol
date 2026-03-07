// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/LiquidationFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/PriceOracleFacet.sol";
import "../contracts/facets/ProtocolFacet.sol";
import "../contracts/facets/PositionManagerFacet.sol";
import "../contracts/facets/VaultManagerFacet.sol";
import "../contracts/Diamond.sol";

import {Pricefeed} from "../contracts/mocks/MockPricefeed.sol";

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

contract DeployPriceFeed is Script, IDiamondCut {
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

    function run() external {
        vm.startBroadcast();
        // address diamondAddress = 0x6A4a39dE0B74E3799f8eDe32F7062289da3F13D8;
        address diamondAddress = 0x0950C8e8807664685A6EFf0a0B20a698a8E7E606; // Spoke testnet
        diamond = Diamond(payable(diamondAddress));

        // address cngnAddress = 0xc4e08f4e2E50efF89B476c9416F0B7B607EDB71a; // base testnet
        address cngnAddress = 0x02FBA47A21Bc82bD323E2aBeE6Fb1892CBA5ecB7; // Avax testnet

        protocolF = ProtocolFacet(address(diamond));
        positionManagerF = PositionManagerFacet(address(diamond));
        vaultManagerF = VaultManagerFacet(address(diamond));
        priceOracleF = PriceOracleFacet(address(diamond));
        liquidationF = LiquidationFacet(address(diamond));

        // Pricefeed _priceFeed = new Pricefeed(8, 72000, msg.sender, 0x8fA510072009E71CfD447169AB5A84cAc394f58A); // base sepolia forwarder
        // Base sepolia pricefeed address 0x7d112B28bdC03879153c7dC06e41e4D90d8265Db
        Pricefeed _priceFeed = new Pricefeed(8, 72000, msg.sender, 0x2E7371a5D032489E4F60216d8D898A4C10805963); // avax sepolia forwarder
        // Avax fuji pricefeed address 0xE7A838e05B6edE1e945Bed16597858f521bb9329
        protocolF.addCollateralToken(cngnAddress, address(_priceFeed), 9000);
        protocolF.removeCollateralToken(cngnAddress);

        console.log("Pricefeed address:", address(_priceFeed));

        vm.stopBroadcast();
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
