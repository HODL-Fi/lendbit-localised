// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";

import "../contracts/interfaces/IDiamondCut.sol";
import "../contracts/facets/DiamondCutFacet.sol";
import "../contracts/facets/DiamondLoupeFacet.sol";
import "../contracts/facets/OwnershipFacet.sol";
import "../contracts/facets/ProtocolFacet.sol";
import "../contracts/facets/PositionManagerFacet.sol";
import "../contracts/facets/VaultManagerFacet.sol";
import "../contracts/facets/PriceOracleFacet.sol";
import "../contracts/facets/LiquidationFacet.sol";
import "../contracts/facets/YieldStrategyFacet.sol";
import "../contracts/facets/GettersFacet.sol";
import "../contracts/Diamond.sol";
import {VaultConfiguration} from "../contracts/models/Protocol.sol";

import {HelperConfig} from "./config/HelperConfig.s.sol";

/// @title DeployLendbit — production-shaped, config-driven deploy for Base + BSC.
/// @notice Reads per-chain values from `HelperConfig` (selected by chainid), deploys
///         the diamond + all 9 facets, registers collateral/borrow markets and roles,
///         optionally wires Chainlink Functions, and transfers ownership to the
///         security-council multisig LAST. Deploys NO mock tokens and seeds no
///         positions. Broadcast key comes from the `PRIVATE_KEY` env var.
///
/// Usage (testnets first):
///   forge script scripts/DeployLendbit.s.sol:DeployLendbit \
///     --rpc-url base_sepolia --broadcast --verify -vvvv
///   forge script scripts/DeployLendbit.s.sol:DeployLendbit \
///     --rpc-url bsc_testnet  --broadcast --verify -vvvv
contract DeployLendbit is Script, IDiamondCut {
    function run() external {
        HelperConfig helper = new HelperConfig();
        HelperConfig.NetworkConfig memory cfg = helper.getConfig();

        // ── Pre-flight: refuse to deploy an unconfigured chain.
        require(cfg.owner != address(0), "owner (multisig) not set in HelperConfig");
        require(cfg.collaterals.length > 0, "no collateral assets configured");
        require(cfg.borrowAssets.length > 0, "no borrow assets configured");
        for (uint256 i; i < cfg.collaterals.length; i++) {
            require(cfg.collaterals[i].token != address(0), "collateral token addr missing");
            require(cfg.collaterals[i].priceFeed != address(0), "collateral price feed missing");
        }
        for (uint256 i; i < cfg.borrowAssets.length; i++) {
            require(cfg.borrowAssets[i].token != address(0), "borrow token addr missing");
            require(cfg.borrowAssets[i].priceFeed != address(0), "borrow price feed missing");
        }

        uint256 _pk = vm.envUint("PRIVATE_KEY");
        address _deployer = vm.addr(_pk);
        console.log("Network            :", cfg.name);
        console.log("Deployer           :", _deployer);
        console.log("Final owner (msig) :", cfg.owner);

        vm.startBroadcast(_pk);

        // ── Deploy diamond + facets (deployer is the initial owner so we can configure).
        DiamondCutFacet dCutFacet = new DiamondCutFacet();
        Diamond diamond = new Diamond(_deployer, address(dCutFacet));

        DiamondLoupeFacet dLoupe = new DiamondLoupeFacet();
        OwnershipFacet ownerF = new OwnershipFacet();
        ProtocolFacet protocolF = new ProtocolFacet();
        PositionManagerFacet positionManagerF = new PositionManagerFacet();
        VaultManagerFacet vaultManagerF = new VaultManagerFacet();
        PriceOracleFacet priceOracleF = new PriceOracleFacet();
        LiquidationFacet liquidationF = new LiquidationFacet();
        YieldStrategyFacet yieldStrategyF = new YieldStrategyFacet();
        GettersFacet gettersF = new GettersFacet();

        FacetCut[] memory cut = new FacetCut[](9);
        cut[0] = _cut(address(dLoupe), "DiamondLoupeFacet");
        cut[1] = _cut(address(ownerF), "OwnershipFacet");
        cut[2] = _cut(address(protocolF), "ProtocolFacet");
        cut[3] = _cut(address(positionManagerF), "PositionManagerFacet");
        cut[4] = _cut(address(vaultManagerF), "VaultManagerFacet");
        cut[5] = _cut(address(priceOracleF), "PriceOracleFacet");
        cut[6] = _cut(address(liquidationF), "LiquidationFacet");
        cut[7] = _cut(address(yieldStrategyF), "YieldStrategyFacet");
        cut[8] = _cut(address(gettersF), "GettersFacet");
        IDiamondCut(address(diamond)).diamondCut(cut, address(0), "");

        // ── Bind the diamond address to the facet ABIs for configuration calls.
        ProtocolFacet protocol = ProtocolFacet(address(diamond));
        VaultManagerFacet vaults = VaultManagerFacet(address(diamond));
        PriceOracleFacet oracle = PriceOracleFacet(address(diamond));
        PositionManagerFacet positions = PositionManagerFacet(address(diamond));

        // ── Protocol rate.
        protocol.setInterestRate(cfg.interestRate, cfg.penaltyRate);

        // ── Collateral markets.
        for (uint256 i; i < cfg.collaterals.length; i++) {
            HelperConfig.CollateralAsset memory a = cfg.collaterals[i];
            protocol.addCollateralToken(a.token, a.priceFeed, a.ltv);
            console.log("collateral added   :", a.label, a.token);
        }

        // ── Borrow-asset vaults.
        for (uint256 i; i < cfg.borrowAssets.length; i++) {
            HelperConfig.BorrowAsset memory b = cfg.borrowAssets[i];
            VaultConfiguration memory vc = VaultConfiguration({
                reserveFactor: b.reserveFactor,
                optimalUtilization: b.optimalUtilization,
                baseRate: b.baseRate,
                slopeRate: b.slopeRate,
                liquidationBonus: b.liquidationBonus,
                totalDeposits: 0,
                totalBorrows: 0,
                lastUpdated: block.timestamp
            });
            address v = vaults.deployVault(b.token, b.priceFeed, b.name, b.symbol, vc);
            console.log("vault deployed     :", b.symbol, v);
        }

        // ── Optional Chainlink Functions wiring (skipped when router unset / on BSC).
        if (cfg.functionsRouter != address(0)) {
            oracle.setupRouter(cfg.donId, cfg.functionsRouter, cfg.link, cfg.subscriptionId);
            if (bytes(cfg.functionsSource).length > 0) oracle.setupSource(cfg.functionsSource);
            console.log("oracle Functions   : wired");
        } else {
            console.log("oracle Functions   : skipped (router unset)");
        }

        // ── Delegated roles (each optional).
        if (cfg.requestBorrowSigner != address(0)) positions.setRequestBorrowSigner(cfg.requestBorrowSigner);
        if (cfg.keeper != address(0)) oracle.setKeeper(cfg.keeper, true);
        if (cfg.whitelister != address(0)) positions.setWhitelister(cfg.whitelister, true);
        if (cfg.guardian != address(0)) vaults.setGuardian(cfg.guardian, true);

        // ── Hand the diamond to the security-council multisig (LAST — after this the
        //    deployer key has no admin power).
        OwnershipFacet(address(diamond)).transferOwnership(cfg.owner);

        vm.stopBroadcast();

        console.log("Diamond            :", address(diamond));
        console.log("Owner after deploy :", OwnershipFacet(address(diamond)).owner());
    }

    // ── selector generation (Node helper, same as the existing testnet script) ──
    function _cut(address _facet, string memory _name) internal returns (FacetCut memory) {
        return FacetCut({
            facetAddress: _facet,
            action: FacetCutAction.Add,
            functionSelectors: generateSelectors(_name)
        });
    }

    function generateSelectors(string memory _facetName) internal returns (bytes4[] memory selectors) {
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "scripts/genSelectors.js";
        cmd[2] = _facetName;
        bytes memory res = vm.ffi(cmd);
        selectors = abi.decode(res, (bytes4[]));
    }

    function diamondCut(FacetCut[] calldata, address, bytes calldata) external override {}
}
