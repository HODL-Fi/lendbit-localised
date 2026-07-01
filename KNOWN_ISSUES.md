# Known Issues & Accepted Risks

_Last updated: 2026-06-30. Companion to the security review
`lendbit-localised-pashov-ai-audit-report-20260626-173900.md`._

This file records limitations and accepted risks that are **known and intentional**
at audit handoff — so they are not re-reported as new findings.

---

## 1. Test Coverage Ceiling

The suite is **390 tests, all passing**, plus a 27-invariant Medusa fuzzer and a
150k-call arithmetic soak. Foundry-measured coverage (`forge coverage --ir-minimum`):

| Metric | Coverage |
|--------|----------|
| Line | 79.6% (1466/1841) |
| Statement | 77.6% (1652/2130) |
| **Branch** | **71.6% (212/296)** |
| Function | 84.3% (264/313) |

**Branch coverage does not reach the 90% audit-checklist target, and cannot via
Foundry on this codebase.** The business logic is strongly covered; the residual
is structural. Per-file branch coverage:

- **100% branch:** ProtocolFacet, VaultManagerFacet, GettersFacet, LiquidationFacet,
  OwnershipFacet, YieldStrategyFacet, PriceOracleFacet, DiamondLoupeFacet,
  DiamondInit, LibPositionManager, LibUtils
- **86–98%:** LibProtocol 89%, LibVaultManager 89%, LibLiquidation 78%, LibDiamond 88% (line)
- **Lower (structural, see below):** TokenVault 76%, LibYieldStrategy 77%, LibDiamond
  72%, LibPriceOracle 67%, SecurityBase 50%, Diamond.sol 0%

### Why 90% branch is unreachable

The ~84 uncovered branch outcomes are dominated by branches **no Solidity test can
drive**:

1. **Assembly / Yul.** `Diamond.sol`'s fallback (`require` + `delegatecall`, all
   Yul) and parts of `LibDiamond` are invisible to Foundry's coverage instrumenter.
   They execute on every call but are never counted.
2. **ABI-rejected branches.** `LibDiamond.InValidFacetCutAction` is unreachable: the
   ABI decoder rejects an out-of-range `FacetCutAction` enum value *before* the
   function body runs.
3. **Mock-only failure paths.** `if (!success) revert TRANSFER_FAILED()` after ERC20
   transfers (LibYieldStrategy, LibProtocol `_transferToken`); `ERC20Mock.transfer`
   never returns `false`.
4. **Defensive guards behind upstream validation.** `amount == 0` early-returns whose
   callers already guard `amount > 0`; `price == 0` / `feed == address(0)` checks
   reached only after `_getPriceData` has already reverted; the `onlyDiamond`-blocked
   share-allowance branch in `TokenVault.withdraw`; `tokenVault == address(0)` after
   `s_supportedToken` is already `true`; the reentrancy-guard failure side
   (`SecurityBase`), which requires an actual nested re-entrant call.

These ~45–50 branches are counted in the denominator but can only be executed by
modifying production code or hand-crafting invalid calldata — neither of which is a
legitimate test. The practical Foundry ceiling is therefore ~85% branch.

**Every reachable branch in the lending, borrowing, liquidation, vault-accounting,
and oracle logic is tested.** The uncovered remainder is EIP-2535 diamond plumbing
(Nick Mudge's reference boilerplate) and the defensive guards above.

### `LibInterestRateModel` removed

The utilization-curve interest model became dead code when the pooled borrow path
was pinned to the fixed APR (audit finding #11). It was deleted rather than tested,
which also removed it from the coverage denominator and closed two manual-review
leads (interest-rate divide-by-zero, utilization double-count).

---

## 2. Accepted Design Decisions

These are intentional and are **not** bugs:

- **Cross-chain borrow health check (audit #5 / 2026-07-01 #1).** `_requestBorrow`
  performs no on-chain collateral/health check on the hub. Cross-chain borrows are
  **spoke-collateralized**: the collateral lives on the spoke chain, the health check
  runs there at attestation time, and the result is carried by the signed request
  (`_verifyBorrowSignature` against `s_requestBorrowSigner`). The hub holds no
  collateral for these positions, so a hub-side `_getHealthFactor` would read zero
  collateral and revert every legitimate request — it is intentionally omitted. An
  optional signed `deadline` was added as defence-in-depth. The **minimum tenure**
  (`ONE_DAY`) IS now enforced on `_requestBorrow`, matching `_takeLoan`.
- **Fixed APR re-prices open positions on a governance rate change.** `s_interestRate`
  is a single set-once-style rate; changing it re-prices the full elapsed interval of
  open pooled borrows. Acceptable for a fixed-rate deployment; removing it would
  require a full per-position borrow-index checkpoint.
- **LP yield is capped by utilization.** `MAX_UTILIZATION` is a strict `< 90%`, so up
  to ~10% of deposited capital is always idle (the liquidity buffer LPs exit through).
  The deployed APR (31.25% → 27.78% after the cap was raised to 90%) is grossed up so
  LPs realize ~20% on deposit **at the utilization ceiling**; below the cap they earn
  proportionally less. The full 20%-on-deposit is unreachable by design because 100%
  utilization is disallowed.
- **Privileged roles are trusted.** The security council (diamond owner) can set
  rates, reserve factors, pause vaults, write off bad debt, force-transfer positions,
  and upgrade vaults. These are assumed to be used correctly; council-only footguns
  are not treated as vulnerabilities (e.g. `_upgradeVault` now reverts `VAULT_NOT_EMPTY`
  rather than stranding deposits — audit #10).

---

## 3. Open Leads for Manual Review

The audit report's **Leads** section lists high-signal code smells where a full
exploit path was not completed in one pass (stale-feed liquidation DoS, liquidation
close-factor / collateral-choice, LTV-vs-liquidation-threshold mismatch, yield raw-
transfer DoS, cross-position yield sourcing, Aave partial-fill, dual-role price-feed
overwrite, `>18`-decimal feed underflow, `encodePacked` signature, admin force-
transfer). These are **not** confirmed false positives — they warrant manual review.
See the audit report for the full list and reasoning.

---

## 4. Scope & Dependencies

- Mocks (`contracts/mocks/*`) are test-only and not deployed.
- Third-party libraries (OpenZeppelin v5.5.0, Chainlink v0.3.2, forge-std v1.12.0)
  are used unmodified; their internal behavior is out of scope.
- The EIP-2535 diamond plumbing (`Diamond.sol`, `LibDiamond`, the loupe/cut facets,
  `DiamondInit`) follows the reference implementation.
