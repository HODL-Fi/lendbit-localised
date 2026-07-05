// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {VaultConfiguration} from "../../contracts/models/Protocol.sol";

/// @title HelperConfig — per-network deployment configuration for lendbit.
/// @notice Fill in the `address(0)` / placeholder slots below with the REAL values
///         for each chain before broadcasting. `getConfig()` selects by `block.chainid`.
///         Supported: Base (8453 — live), BSC (56 — live), Base Sepolia (84532),
///         BSC Testnet (97).
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
        uint16 liquidationThreshold; // bps; 0 = protocol default (9000). Must be >= ltv.
        uint32 stalenessThreshold; // seconds; 0 = protocol default (3600). Size to the feed's heartbeat.
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
        uint32 stalenessThreshold; // seconds; 0 = protocol default (3600). Size to the feed's heartbeat.
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

    function getConfigByChainId(uint256 _chainId) public view returns (NetworkConfig memory) {
        if (_chainId == 8453) return _base();
        if (_chainId == 56) return _bsc();
        if (_chainId == 84532) return _baseSepolia();
        if (_chainId == 97) return _bscTestnet();
        revert UnsupportedChain(_chainId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Base (8453) — mirrors the LIVE diamond 0xEB78Ac64745162D1d3942226607d18F8B261689D
    //  as of 2026-07-04 (owner, rates, collateral markets, staleness thresholds
    //  read back on-chain). The live deployment is collateral-only: no borrow
    //  vaults exist yet, so `borrowAssets` is empty and the deploy pre-flight
    //  will refuse a fresh broadcast until at least one is configured.
    // ─────────────────────────────────────────────────────────────────────────
    function _base() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "base";
        // Live owner is an EOA, not a multisig (DEPLOY.md recommends a Safe here).
        cfg.owner = 0xb159588fc04378B8334BA49593aAa3966663ACe1;
        // 22.45% APR: at the 90% utilization cap with a 1% reserve factor this pays
        // LPs exactly 20% APY (22.45 × 0.90 × 0.99) and the protocol 1% of interest
        // revenue. Future vaults on this chain must use reserveFactor = 100 to match.
        cfg.interestRate = 2245;
        cfg.penaltyRate = 500;

        // Chainlink Functions: not wired on the live diamond (router/donId/sub all zero).
        cfg.link = address(0);
        cfg.functionsRouter = address(0);
        cfg.donId = bytes32(0);
        cfg.subscriptionId = 0;
        cfg.functionsSource = "";

        cfg.requestBorrowSigner = 0xb159588fc04378B8334BA49593aAa3966663ACe1; // same as owner on-chain
        // Mapping-based roles cannot be enumerated on-chain; the owner holds none of
        // them (isKeeper/isWhitelister/isGuardian(owner) == false). Grant post-deploy.
        cfg.keeper = address(0);
        cfg.whitelister = address(0);
        cfg.guardian = address(0);

        // Feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=base
        // Stablecoin feeds on Base have a 24 h heartbeat → 90000 s (24 h + 1 h buffer).
        // ETH/USD updates frequently → protocol default (3600) is fine.
        CollateralAsset[] memory _cols = new CollateralAsset[](4);
        _cols[0] = CollateralAsset({
            label: "ETH", // native-ETH sentinel
            token: address(1),
            priceFeed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70, // ETH / USD
            ltv: 8000,
            liquidationThreshold: 8500,
            stalenessThreshold: 0
        });
        _cols[1] = CollateralAsset({
            label: "USDC",
            token: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            priceFeed: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B, // USDC / USD
            ltv: 8500,
            liquidationThreshold: 0,
            stalenessThreshold: 90000
        });
        _cols[2] = CollateralAsset({
            label: "DAI",
            token: 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb,
            priceFeed: 0x591e79239a7d679378eC8c847e5038150364C78F, // DAI / USD
            ltv: 8500,
            liquidationThreshold: 0,
            stalenessThreshold: 90000
        });
        _cols[3] = CollateralAsset({
            label: "USDT",
            token: 0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2,
            priceFeed: 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9, // USDT / USD
            ltv: 8500,
            liquidationThreshold: 0,
            stalenessThreshold: 90000
        });
        cfg.collaterals = _cols;

        // No borrow vaults on the live diamond yet (tokenIsSupported == false for
        // every collateral; getTokenVault returns zero). Configure before any
        // fresh deploy — the pre-flight requires at least one borrow asset.
        cfg.borrowAssets = new BorrowAsset[](0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  BSC (56) — mirrors the LIVE diamond 0xa122e4D704B21E17955c49520F31087a67194E25
    //  as of 2026-07-05, after aligning it with Base (interestRate 2778→2245,
    //  USDC LTV 9000→8500, DAI LTV 8000→8500) and de-risking the volatile natives
    //  (BNB 7500/8300, peg-ETH 8000/8500 — LT off the 9000 default so the 10%
    //  liquidation bonus can't exceed collateral during a gap move).
    //  Collateral-only like Base: no borrow vaults exist yet.
    // ─────────────────────────────────────────────────────────────────────────
    function _bsc() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "bsc";
        // Live owner is an EOA, not a multisig (DEPLOY.md recommends a Safe here).
        cfg.owner = 0xb159588fc04378B8334BA49593aAa3966663ACe1;
        // 22.45% APR: same 20% LP APY / 1% reserve-factor economics as Base (see _base()).
        cfg.interestRate = 2245;
        cfg.penaltyRate = 500;

        // Chainlink Functions is NOT supported on BNB Chain — keep these zero.
        cfg.link = address(0);
        cfg.functionsRouter = address(0);
        cfg.donId = bytes32(0);
        cfg.subscriptionId = 0;
        cfg.functionsSource = "";

        cfg.requestBorrowSigner = 0xb159588fc04378B8334BA49593aAa3966663ACe1; // same as owner on-chain
        cfg.keeper = address(0);
        cfg.whitelister = address(0);
        cfg.guardian = address(0);

        // Feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=bnb-chain
        // BSC feeds update fast (minutes, not 24 h like Base stables), so the
        // protocol default staleness threshold (3600) is sufficient — leave 0.
        CollateralAsset[] memory _cols = new CollateralAsset[](5);
        _cols[0] = CollateralAsset({
            label: "BNB", // native-BNB sentinel
            token: address(1),
            priceFeed: 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE, // BNB / USD
            ltv: 7500,
            liquidationThreshold: 8300,
            stalenessThreshold: 0
        });
        _cols[1] = CollateralAsset({
            label: "ETH", // Binance-peg ETH
            token: 0x2170Ed0880ac9A755fd29B2688956BD959F933F8,
            priceFeed: 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e, // ETH / USD
            ltv: 8000,
            liquidationThreshold: 8500,
            stalenessThreshold: 0
        });
        _cols[2] = CollateralAsset({
            label: "USDC",
            token: 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d,
            priceFeed: 0x51597f405303C4377E36123cBc172b13269EA163, // USDC / USD
            ltv: 8500,
            liquidationThreshold: 0,
            stalenessThreshold: 0
        });
        _cols[3] = CollateralAsset({
            label: "USDT",
            token: 0x55d398326f99059fF775485246999027B3197955,
            priceFeed: 0xB97Ad0E74fa7d920791E90258A6E2085088b4320, // USDT / USD
            ltv: 8500,
            liquidationThreshold: 0,
            stalenessThreshold: 0
        });
        _cols[4] = CollateralAsset({
            label: "DAI",
            token: 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3,
            priceFeed: 0x132d3C0B1D2cEa0BC552588063bdBb210FDeecfA, // DAI / USD
            ltv: 8500,
            liquidationThreshold: 0,
            stalenessThreshold: 0
        });
        cfg.collaterals = _cols;

        // No borrow vaults on the live diamond yet. Configure before any fresh
        // deploy — the pre-flight requires at least one borrow asset.
        cfg.borrowAssets = new BorrowAsset[](0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Base Sepolia (84532)  —  FILL IN THE ADDRESSES
    // ─────────────────────────────────────────────────────────────────────────
    function _baseSepolia() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "base-sepolia";
        cfg.owner = address(0); // TODO: Base Sepolia security-council multisig
        // 22.45% APR: at the 90% utilization cap with a 1% reserve factor this pays
        // LPs exactly 20% APY (22.45 x 0.90 x 0.99) and the protocol 1% of interest revenue.
        cfg.interestRate = 2245;
        cfg.penaltyRate = 500;

        // Chainlink Functions on Base Sepolia (optional). Fill to enable, else leave zero.
        cfg.link = address(0); // TODO: LINK token
        cfg.functionsRouter = address(0); // TODO: Functions router
        cfg.donId = bytes32(0); // TODO: DON id
        cfg.subscriptionId = 0; // TODO: Functions subscription id
        cfg.functionsSource = ""; // TODO: JS source (leave empty to skip)

        cfg.requestBorrowSigner = address(0); // TODO: cross-chain attestation signer
        cfg.keeper = address(0); // TODO: price-refresh keeper (optional)
        cfg.whitelister = address(0); // TODO: automated onboarding key (optional)
        cfg.guardian = address(0); // TODO: pause-only guardian (optional)

        CollateralAsset[] memory _cols = new CollateralAsset[](2);
        _cols[0] = CollateralAsset({label: "WETH", token: address(0), priceFeed: address(0), ltv: 8000, liquidationThreshold: 8500, stalenessThreshold: 0}); // TODO
        _cols[1] = CollateralAsset({label: "USDC", token: address(0), priceFeed: address(0), ltv: 8500, liquidationThreshold: 0, stalenessThreshold: 90000}); // TODO
        cfg.collaterals = _cols;

        BorrowAsset[] memory _borrows = new BorrowAsset[](1);
        _borrows[0] = BorrowAsset({
            label: "USDC",
            token: address(0), // TODO
            priceFeed: address(0), // TODO
            name: "Lendbit USDC",
            symbol: "lbUSDC",
            reserveFactor: 100,
            baseRate: 500,
            slopeRate: 1500,
            optimalUtilization: 7500,
            liquidationBonus: 1000,
            stalenessThreshold: 90000
        });
        cfg.borrowAssets = _borrows;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  BSC Testnet (97)  —  FILL IN THE ADDRESSES
    // ─────────────────────────────────────────────────────────────────────────
    function _bscTestnet() internal pure returns (NetworkConfig memory cfg) {
        cfg.name = "bsc-testnet";
        cfg.owner = address(0); // TODO: BSC Testnet security-council multisig
        // 22.45% APR — same 20% LP APY / 1% reserve-factor economics as Base (see _base()).
        cfg.interestRate = 2245;
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
        _cols[0] = CollateralAsset({label: "WBNB", token: address(0), priceFeed: address(0), ltv: 8000, liquidationThreshold: 8500, stalenessThreshold: 0}); // TODO
        _cols[1] = CollateralAsset({label: "USDT", token: address(0), priceFeed: address(0), ltv: 8500, liquidationThreshold: 0, stalenessThreshold: 90000}); // TODO
        cfg.collaterals = _cols;

        BorrowAsset[] memory _borrows = new BorrowAsset[](1);
        _borrows[0] = BorrowAsset({
            label: "USDT",
            token: address(0), // TODO
            priceFeed: address(0), // TODO
            name: "Lendbit USDT",
            symbol: "lbUSDT",
            reserveFactor: 100,
            baseRate: 500,
            slopeRate: 1500,
            optimalUtilization: 7500,
            liquidationBonus: 1000,
            stalenessThreshold: 90000
        });
        cfg.borrowAssets = _borrows;
    }
}
