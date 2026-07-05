// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {VaultConfiguration} from "../../contracts/models/Protocol.sol";

/// @title HelperConfig — per-network deployment configuration for lendbit.
/// @notice Fill in the `address(0)` / placeholder slots below with the REAL values
///         for each chain before broadcasting. `getConfig()` selects by `block.chainid`.
///         Supported (testnets first): Base Sepolia (84532), BSC Testnet (97).
///
/// Where to source the real values:
///  - Token addresses: the canonical testnet token deployments you intend to support.
///  - Price feeds: Chainlink Data Feeds → https://docs.chain.link/data-feeds/price-feeds/addresses
///  - Functions router / DON id: https://docs.chain.link/chainlink-functions/supported-networks
///    (NOTE: Chainlink Functions is NOT available on BNB Chain — leave functionsRouter
///     as address(0) for BSC; core valuation uses the standard price feeds regardless.)
///  - owner: the per-chain Safe/multisig that becomes the security council.
contract HelperConfig is Script {
    error UnsupportedChain(uint256 chainId);

    struct CollateralAsset {
        string label; // human label, e.g. "WETH"
        address token;
        address priceFeed; // Chainlink aggregator
        uint16 ltv; // origination limit, bps (must be <= liquidation threshold, default 9000)
    }

    struct BorrowAsset {
        string label; // e.g. "USDC"
        address token;
        address priceFeed;
        string name; // vault share token name
        string symbol; // vault share token symbol
        uint16 reserveFactor; // bps (<= 10000)
        uint16 baseRate; // bps
        uint16 slopeRate; // bps (>= baseRate)
        uint16 optimalUtilization; // bps (>= 5000)
        uint16 liquidationBonus; // bps (<= 1000)
    }

    struct NetworkConfig {
        string name;
        address owner; // security-council multisig (ownership transferred here at the end)
        uint16 interestRate; // protocol annual rate, bps
        uint16 penaltyRate; // overdue penalty, bps
        // Chainlink Functions (optional — leave zero to skip; unavailable on BSC)
        address link;
        address functionsRouter;
        bytes32 donId;
        uint64 subscriptionId;
        string functionsSource;
        // delegated roles (leave zero to skip granting during deploy)
        address requestBorrowSigner;
        address keeper;
        address whitelister;
        address guardian;
        CollateralAsset[] collaterals;
        BorrowAsset[] borrowAssets;
    }

    /// @notice Return the config for the current chain.
    function getConfig() public view returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    function getConfigByChainId(uint256 _chainId) public pure returns (NetworkConfig memory) {
        if (_chainId == 8453) return _baseMainnet();
        if (_chainId == 84532) return _baseSepolia();
        if (_chainId == 97) return _bscTestnet();
        if (_chainId == 56) return _bscMainnet();
        revert UnsupportedChain(_chainId);
    }

    function _baseMainnet() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "base-mainnet";
        cfg.owner = address(0xb159588fc04378B8334BA49593aAa3966663ACe1); // TODO: Base Sepolia security-council multisig
        cfg.interestRate = 2778; // 27.78% (grossed up for the 90% utilization cap)
        cfg.penaltyRate = 500;

        // Chainlink Functions on Base Sepolia (optional). Fill to enable, else leave zero.
        cfg.link = address(0); // TODO: LINK token
        cfg.functionsRouter = address(0); // TODO: Functions router
        cfg.donId = bytes32(0); // TODO: DON id
        cfg.subscriptionId = 0; // TODO: Functions subscription id
        cfg.functionsSource = ""; // TODO: JS source (leave empty to skip)

        cfg.requestBorrowSigner = address(0xb159588fc04378B8334BA49593aAa3966663ACe1); // TODO: cross-chain attestation signer
        cfg.keeper = address(0); // TODO: price-refresh keeper (optional)
        cfg.whitelister = address(0); // TODO: automated onboarding key (optional)
        cfg.guardian = address(0); // TODO: pause-only guardian (optional)

        CollateralAsset[] memory _cols = new CollateralAsset[](4);
        _cols[0] = CollateralAsset({
            label: "ETH", token: address(1), priceFeed: address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70), ltv: 8000
        });
        _cols[1] = CollateralAsset({
            label: "USDC",
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            priceFeed: address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B),
            ltv: 8500
        });
        _cols[2] = CollateralAsset({
            label: "DAI",
            token: address(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb),
            priceFeed: address(0x591e79239a7d679378eC8c847e5038150364C78F),
            ltv: 8500
        });
        _cols[3] = CollateralAsset({
            label: "LINK",
            token: address(0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196),
            priceFeed: address(0x17CAb8FE31E32f08326e5E27412894e49B0f9D65),
            ltv: 8000
        });
        cfg.collaterals = _cols;

        BorrowAsset[] memory _borrows = new BorrowAsset[](1);
        _borrows[0] = BorrowAsset({
            label: "CNGN",
            token: address(0x46C85152bFe9f96829aA94755D9f915F9B10EF5F), // TODO
            priceFeed: address(0xdfbb5Cbc88E382de007bfe6CE99C388176ED80aD), // TODO
            name: "Compliant Naira",
            symbol: "CNGN",
            reserveFactor: 2000,
            baseRate: 500,
            slopeRate: 1500,
            optimalUtilization: 7500,
            liquidationBonus: 1000
        });
        cfg.borrowAssets = _borrows;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Base Sepolia (84532)  —  FILL IN THE ADDRESSES
    // ─────────────────────────────────────────────────────────────────────────
    function _baseSepolia() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "base-sepolia";
        cfg.owner = address(0xb159588fc04378B8334BA49593aAa3966663ACe1); // TODO: Base Sepolia security-council multisig
        cfg.interestRate = 2778; // 27.78% (grossed up for the 90% utilization cap)
        cfg.penaltyRate = 500;

        // Chainlink Functions on Base Sepolia (optional). Fill to enable, else leave zero.
        cfg.link = address(0); // TODO: LINK token
        cfg.functionsRouter = address(0); // TODO: Functions router
        cfg.donId = bytes32(0); // TODO: DON id
        cfg.subscriptionId = 0; // TODO: Functions subscription id
        cfg.functionsSource = ""; // TODO: JS source (leave empty to skip)

        cfg.requestBorrowSigner = address(0xb159588fc04378B8334BA49593aAa3966663ACe1); // TODO: cross-chain attestation signer
        cfg.keeper = address(0); // TODO: price-refresh keeper (optional)
        cfg.whitelister = address(0); // TODO: automated onboarding key (optional)
        cfg.guardian = address(0); // TODO: pause-only guardian (optional)

        CollateralAsset[] memory _cols = new CollateralAsset[](2);
        // _cols[0] = CollateralAsset({label: "WETH", token: address(0), priceFeed: address(0), ltv: 8000}); // TODO
        // _cols[1] = CollateralAsset({label: "USDC", token: address(0), priceFeed: address(0), ltv: 8500}); // TODO

        _cols[0] = CollateralAsset({
            label: "ETH", token: address(1), priceFeed: address(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70), ltv: 8000
        });
        _cols[1] = CollateralAsset({
            label: "USDC",
            token: address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913),
            priceFeed: address(0x7e860098F58bBFC8648a4311b374B1D669a2bc6B),
            ltv: 8500
        });
        _cols[2] = CollateralAsset({label: "WETH", token: address(0), priceFeed: address(0), ltv: 8000});
        _cols[3] = CollateralAsset({label: "USDC", token: address(0), priceFeed: address(0), ltv: 8500});
        cfg.collaterals = _cols;

        BorrowAsset[] memory _borrows = new BorrowAsset[](1);
        _borrows[0] = BorrowAsset({
            label: "USDC",
            token: address(0), // TODO
            priceFeed: address(0), // TODO
            name: "Lendbit USDC",
            symbol: "lbUSDC",
            reserveFactor: 2000,
            baseRate: 500,
            slopeRate: 1500,
            optimalUtilization: 7500,
            liquidationBonus: 1000
        });
        cfg.borrowAssets = _borrows;
    }

    function _bscMainnet() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "bsc-mainnet";
        cfg.owner = address(0xb159588fc04378B8334BA49593aAa3966663ACe1); // TODO: Base Sepolia security-council multisig
        cfg.interestRate = 2778; // 27.78% (grossed up for the 90% utilization cap)
        cfg.penaltyRate = 500;

        // Chainlink Functions on Base Sepolia (optional). Fill to enable, else leave zero.
        cfg.link = address(0); // TODO: LINK token
        cfg.functionsRouter = address(0); // TODO: Functions router
        cfg.donId = bytes32(0); // TODO: DON id
        cfg.subscriptionId = 0; // TODO: Functions subscription id
        cfg.functionsSource = ""; // TODO: JS source (leave empty to skip)

        cfg.requestBorrowSigner = address(0xb159588fc04378B8334BA49593aAa3966663ACe1); // TODO: cross-chain attestation signer
        cfg.keeper = address(0); // TODO: price-refresh keeper (optional)
        cfg.whitelister = address(0); // TODO: automated onboarding key (optional)
        cfg.guardian = address(0); // TODO: pause-only guardian (optional)

        CollateralAsset[] memory _cols = new CollateralAsset[](5);
        _cols[0] = CollateralAsset({
            label: "BNB", token: address(1), priceFeed: address(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE), ltv: 8000
        });
        _cols[1] = CollateralAsset({
            label: "ETH",
            token: address(0x2170Ed0880ac9A755fd29B2688956BD959F933F8),
            priceFeed: address(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e),
            ltv: 8000
        });
        _cols[2] = CollateralAsset({
            label: "USDC",
            token: address(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d),
            priceFeed: address(0x51597f405303C4377E36123cBc172b13269EA163),
            ltv: 9000
        });
        _cols[3] = CollateralAsset({
            label: "USDT",
            token: address(0x55d398326f99059fF775485246999027B3197955),
            priceFeed: address(0xB97Ad0E74fa7d920791E90258A6E2085088b4320),
            ltv: 8500
        });
        _cols[4] = CollateralAsset({
            label: "DAI",
            token: address(0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3),
            priceFeed: address(0x132d3C0B1D2cEa0BC552588063bdBb210FDeecfA),
            ltv: 8000
        });
        cfg.collaterals = _cols;

        BorrowAsset[] memory _borrows = new BorrowAsset[](1);
        _borrows[0] = BorrowAsset({
            label: "CNGN",
            token: address(0xa8AEA66B361a8d53e8865c62D142167Af28Af058), // TODO
            priceFeed: address(0x09f1458a15F8b0064450a8098D23443531fC6f95), // TODO
            name: "Compliant Naira",
            symbol: "CNGN",
            reserveFactor: 2000,
            baseRate: 500,
            slopeRate: 1500,
            optimalUtilization: 7500,
            liquidationBonus: 1000
        });
        cfg.borrowAssets = _borrows;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  BSC Testnet (97)  —  FILL IN THE ADDRESSES
    // ─────────────────────────────────────────────────────────────────────────
    function _bscTestnet() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "bsc-testnet";
        cfg.owner = address(0); // TODO: BSC Testnet security-council multisig
        cfg.interestRate = 2778;
        cfg.penaltyRate = 500;

        // Chainlink Functions is NOT supported on BNB Chain — keep these zero.
        cfg.link = address(0);
        cfg.functionsRouter = address(0);
        cfg.donId = bytes32(0);
        cfg.subscriptionId = 0;
        cfg.functionsSource = "";

        cfg.requestBorrowSigner = address(0); // TODO
        cfg.keeper = address(0);
        cfg.whitelister = address(0);
        cfg.guardian = address(0);

        CollateralAsset[] memory _cols = new CollateralAsset[](2);
        _cols[0] = CollateralAsset({label: "WBNB", token: address(0), priceFeed: address(0), ltv: 8000}); // TODO
        _cols[1] = CollateralAsset({label: "USDT", token: address(0), priceFeed: address(0), ltv: 8500}); // TODO
        cfg.collaterals = _cols;

        BorrowAsset[] memory _borrows = new BorrowAsset[](1);
        _borrows[0] = BorrowAsset({
            label: "USDT",
            token: address(0), // TODO
            priceFeed: address(0), // TODO
            name: "Lendbit USDT",
            symbol: "lbUSDT",
            reserveFactor: 2000,
            baseRate: 500,
            slopeRate: 1500,
            optimalUtilization: 7500,
            liquidationBonus: 1000
        });
        cfg.borrowAssets = _borrows;
    }
}
