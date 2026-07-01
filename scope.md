# Audit Scope — lendbit-localised

_Last updated: 2026-07-01. Companion to `KNOWN_ISSUES.md` and the security review
`lendbit-localised-pashov-ai-audit-report-20260626-173900.md`._

Lendbit is an EIP-2535 (Diamond) lending protocol: LPs deposit into per-token
ERC-4626 vaults, borrowers post collateral and take fixed-rate loans (local or
cross-chain), idle collateral is routed to Aave for yield, and under-collateralized
positions/loans are liquidated. Interest is charged at a single protocol-set APR;
a `reserveFactor` splits it between LPs and the protocol.

## Chains

- **Hub chain** — where this diamond is deployed; holds vaults, loans, collateral
  accounting, and disbursement. EVM-compatible (Solidity `0.8.30`, `cancun`).
- **Spoke chains** — in the cross-chain borrow flow, collateral is posted and the
  health check runs on the spoke; a trusted signer attests the result, and
  `ProtocolFacet.requestBorrow` disburses on the hub against that signature. Spoke
  contracts are **out of scope** for this review.

## In-scope contracts

### Diamond core (EIP-2535)
- `contracts/Diamond.sol`
- `contracts/upgradeInitializers/DiamondInit.sol`
- `contracts/facets/DiamondCutFacet.sol`
- `contracts/facets/DiamondLoupeFacet.sol`
- `contracts/facets/OwnershipFacet.sol`
- `contracts/libraries/LibDiamond.sol`

### Business facets (external entry points)
- `contracts/facets/ProtocolFacet.sol` — `depositCollateral`, `withdrawCollateral`,
  `borrow`, `repay`, `takeLoan`, `requestBorrow`, `repayLoan`, `repayLoanFor`,
  `addCollateralToken`, `removeCollateralToken`, `setInterestRate`,
  `setCollateralTokenLtv`
- `contracts/facets/VaultManagerFacet.sol` — `deposit`, `withdraw`, `deployVault`,
  `upgradeVault`, `setReserveFactor`, `setBaseRate`, `setSlopeRate`,
  `setOptimalUtilization`, `setLiquidationBonus`, `pauseTokenSupport`,
  `resumeTokenSupport`, `harvestVaultReserve`, `writeOffBadDebt`, `setVaultPaused`,
  getters
- `contracts/facets/LiquidationFacet.sol` — `isLiquidatable`, `liquidateLoan`,
  `liquidatePosition`
- `contracts/facets/PositionManagerFacet.sol` — `createPositionFor`,
  `transferPositionOwnership`, `adminForceTransferPositionOwnership`,
  `whitelistAddress`, `blacklistAddress`, `setRequestBorrowSigner`, getters
- `contracts/facets/YieldStrategyFacet.sol` — `configureYieldToken`, `setYieldPause`,
  `rebalanceMyPosition`, `claimYield`, `harvestProtocolYield`, getters
- `contracts/facets/PriceOracleFacet.sol` — price reads, Chainlink Functions admin,
  `sendRequest` (keeper-gated), `handleOracleFulfillment`
- `contracts/facets/GettersFacet.sol` — view aggregators (health factor, debt,
  collateral value, loan/vault details)

### Vault
- `contracts/TokenVault.sol` — ERC-4626 vault with time-weighted interest accrual,
  a protocol reserve, borrow/repay, bad-debt write-off, and pause.

### Libraries
- `contracts/libraries/LibProtocol.sol`
- `contracts/libraries/LibVaultManager.sol`
- `contracts/libraries/LibLiquidation.sol`
- `contracts/libraries/LibYieldStrategy.sol`
- `contracts/libraries/LibPriceOracle.sol`
- `contracts/libraries/LibPositionManager.sol`
- `contracts/libraries/LibUtils.sol`
- `contracts/libraries/LibAppStorage.sol`
- `contracts/libraries/SecurityBase.sol`

### Models & interfaces
- `contracts/models/*` (`Constant`, `Error`, `Event`, `Protocol`, `Yield`,
  `FunctionParams`)
- `contracts/interfaces/*` (`IDiamondCut`, `IDiamondLoupe`, `IERC165`,
  `IERC173`, `IVaultManager`)

## Out of scope

- `contracts/mocks/*` — test-only, never deployed.
- Third-party dependencies (OpenZeppelin v5.5.0, Chainlink v0.3.2, forge-std) —
  used unmodified.
- Spoke-chain contracts and the off-chain attestation signer.
- `contracts/libraries/LibInterestRateModel.sol` — **removed** (dead code after the
  borrow path was pinned to the fixed APR; see `KNOWN_ISSUES.md`).

## Trust assumptions

- The **security council** (diamond owner) is trusted for privileged operations
  (rates, reserve factor, pause, bad-debt write-off, vault upgrade, position force-
  transfer). See `KNOWN_ISSUES.md` §2.
- The **request-borrow signer** is trusted to attest spoke-chain collateral/health.
- Price feeds are Chainlink aggregators; staleness/round/positive-answer checks are
  enforced in `LibPriceOracle._getPriceData`.

## Entry-point summary

| Actor | Can call |
|-------|----------|
| LP | `deposit`, `withdraw` (VaultManagerFacet) |
| Borrower (whitelisted) | `depositCollateral`, `withdrawCollateral`, `borrow`, `repay`, `takeLoan`, `repayLoan`, `claimYield`, `rebalanceMyPosition` |
| Keeper (whitelisted) | `sendRequest`, `repayLoanFor`, liquidation entrypoints |
| Anyone | `liquidateLoan`, `liquidatePosition` (only when the target is liquidatable), view getters |
| Security council (owner) | vault deploy/upgrade/config, rate setters, pause, bad-debt write-off, collateral-token management, whitelist/blacklist, oracle admin |
