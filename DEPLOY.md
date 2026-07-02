# Deployment Runbook — Base + BSC (testnets first)

Config-driven deploy via `scripts/DeployLendbit.s.sol` + `scripts/config/HelperConfig.s.sol`.
Deploys the diamond + all 9 facets, registers collateral/borrow markets and roles,
optionally wires Chainlink Functions, and **transfers ownership to the security-council
multisig last**. No mock tokens, no seeded positions.

## 0. Prerequisites
- A funded **deployer key** on each testnet (throwaway — it holds no admin power after deploy).
- A **security-council multisig** (e.g. a Safe) deployed on each chain → this becomes the owner.
- Real per-chain addresses: collateral + borrow tokens, their **Chainlink price feeds**
  (https://docs.chain.link/data-feeds/price-feeds/addresses), and — only if you want the
  Functions oracle — LINK / Functions router / DON id / subscription
  (https://docs.chain.link/chainlink-functions/supported-networks).
  Note: **Chainlink Functions is not available on BNB Chain** — leave those zero for BSC;
  valuation uses the standard price feeds on both chains regardless.

## 1. Fill the config
Edit `scripts/config/HelperConfig.s.sol` — replace every `address(0)` / `bytes32(0)` /
`0` placeholder marked `TODO` in `_baseSepolia()` (chainid 84532) and `_bscTestnet()`
(chainid 97): `owner`, each collateral `{token, priceFeed, ltv}`, each borrow
`{token, priceFeed}`, and any roles/oracle you want set at deploy. Sanity bounds enforced
on-chain: collateral `ltv <= 9000` (≤ liquidation threshold), vault `liquidationBonus <= 1000`,
`reserveFactor <= 10000`, `optimalUtilization >= 5000`.

## 2. Env
```
cp .env.example .env      # then fill PRIVATE_KEY, RPC URLs, explorer API keys
source .env
```

## 3. Dry run (simulation, no broadcast)
```
forge script scripts/DeployLendbit.s.sol:DeployLendbit --rpc-url base_sepolia -vvvv
forge script scripts/DeployLendbit.s.sol:DeployLendbit --rpc-url bsc_testnet  -vvvv
```
The pre-flight reverts with a clear message if any required address is still unset.

## 4. Broadcast + verify
```
forge script scripts/DeployLendbit.s.sol:DeployLendbit --rpc-url base_sepolia --broadcast --verify -vvvv
forge script scripts/DeployLendbit.s.sol:DeployLendbit --rpc-url bsc_testnet  --broadcast --verify -vvvv
```
(For mainnet later: `--rpc-url base` / `--rpc-url bsc`, after a clean testnet run.)

## 5. Post-deploy verification
- `OwnershipFacet(diamond).owner()` == your multisig (the script logs this).
- Loupe: `cast call <diamond> "facetAddresses()(address[])"` returns 9 facets.
- Each collateral/vault registered (`getAllCollateralTokens`, `getTokenVault`).
- Roles reflect config (`isGuardian`, `isWhitelister`, `getRequestBorrowSigner`, `isKeeper`).
- From here, all admin actions must originate from the multisig.

## Notes
- `evm_version = 'cancun'` — required by OpenZeppelin v5.5.0 (MCOPY); supported on both
  Base (Ecotone) and BNB Chain (Tycho).
- `scripts/Deploy.s.sol` is the older **local/testnet mock** script (mints mock tokens,
  seeds a position) — do NOT use it for a real deployment; use `DeployLendbit.s.sol`.
- Whitelisting is required for users to interact — onboard addresses post-deploy via the
  council or a delegated whitelister.
