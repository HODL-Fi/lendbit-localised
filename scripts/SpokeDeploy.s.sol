// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

import {LendbitSpoke} from "../contracts/LendbitSpoke.sol";

import {console} from "forge-std/console.sol";
import {Script} from "forge-std/Script.sol";

contract Deployment is Script {
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

    LendbitSpoke lendbitSpoke;
    MockV3Aggregator cngnPricefeed;
    ERC20Mock cngnToken;

    function run() external {
        vm.startBroadcast();
        address admin = 0xb159588fc04378B8334BA49593aAa3966663ACe1;
        // lendbitSpoke = LendbitSpoke(0x0D7F896905663879bD384A9D7617593e8095AF10);
        lendbitSpoke = new LendbitSpoke(0x2E7371a5D032489E4F60216d8D898A4C10805963);
        // cngnPricefeed = new MockV3Aggregator(8, 70287);
        cngnPricefeed = MockV3Aggregator(0xFAcB3a0c911381693f07caa46B8ce383160288Ba);
        // cngnToken = new ERC20Mock(6);
        cngnToken = ERC20Mock(0x02FBA47A21Bc82bD323E2aBeE6Fb1892CBA5ecB7);

        console.log("Deployed Addresses:");
        console.log("LendbitSpoke: ", address(lendbitSpoke));
        console.log("CNGN Pricefeed: ", address(cngnPricefeed));
        console.log("CNGN Token: ", address(cngnToken));

        token1 = address(1); // AVAX
        token2 = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846; // LINK
        token3 = address(cngnToken); // CNGN
        token4 = 0x4b0e4997d74F3a2D998f8CbD86F0201fA018233D; // USDC
        token5 = 0x5bd836f690c299F8912135d36812889B6C369780; // DAI

        pricefeed1 = 0x5498BB86BC934c8D34FDA08E81D444153d0D06aD; // AVAX/USD
        pricefeed2 = 0x34C4c526902d88a3Aa98DB8a9b802603EB1E3470; // LINK/USD
        pricefeed3 = 0xFAcB3a0c911381693f07caa46B8ce383160288Ba; // CNGN/USD
        pricefeed4 = 0x97FE42a7E96640D932bbc0e1580c73E705A8EB73;
        pricefeed5 = 0x97FE42a7E96640D932bbc0e1580c73E705A8EB73; // Using same pricefeed for DAI/USD and USDC/USD for testing

        // Setup initial collateral tokens
        _setupInitialCollateralAndBorrowTokens();
        lendbitSpoke.setInterestRate(2000, 500);
        lendbitSpoke.addSupportedToken(address(cngnToken), address(cngnPricefeed));
        lendbitSpoke.setRequestSigner(admin);
        lendbitSpoke.whitelistAddress(admin);
        lendbitSpoke.createPositionFor(admin);

        vm.stopBroadcast();
    }

    function _setupInitialCollateralAndBorrowTokens() internal {
        lendbitSpoke.addCollateralToken(token1, pricefeed1, 8000);
        lendbitSpoke.addCollateralToken(token2, pricefeed2, 8000);
        // lendbitSpoke.addCollateralToken(token3, pricefeed3, 8000);
        lendbitSpoke.addCollateralToken(token4, pricefeed4, 9000);
        lendbitSpoke.addCollateralToken(token5, pricefeed5, 9000); // Native token
    }
}
