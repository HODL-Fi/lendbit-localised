# Remediation — Lendbit Security Review

_Tracking doc for fixes against the security review (gist `d8810c0a`). Reviewed
commit `c8a75de`. Branch: `track1-remediation`._

Fixes split by **upgrade surface**, because the protocol has two:

- **Diamond facets** — shippable live via `diamondCut`. Storage changes are
  append-only to `LibAppStorage.StorageLayout`.
- **`TokenVault`** — a plain deployed ERC4626 per token, **not** behind a proxy.
  Its only upgrade path is `_upgradeVault`, which reverts `VAULT_NOT_EMPTY` while
  the vault holds any shares or borrows. The live Base vault has open borrows, so
  vault-side fixes **cannot** be shipped to it in place — they ship to new markets
  and pre-stage the eventual redeploy of the existing vaults.

## Status

| Finding | Severity | Surface | Status | Commit |
|---|---|---|---|---|
| H-01 unbounded tenure | High/Med | diamond | Fixed | `fe54d59` |
| M-02 penalty double-charge | Med(→High arg) | diamond | Fixed | `fe54d59` |
| M-05 whitelist reverses blacklist | Low | diamond | Fixed | `fe54d59` |
| M-07 rebalance skips freeze | Med(defence) | diamond | Fixed | `fe54d59` |
| L-10 unbounded reserve factor | Low | vault ctor | Fixed | `fe54d59` |
| M-09 fixed-leg invariant break | Med | vault | Fixed, **staged for redeploy** | `0ec0420` |
| M-04 blacklist bypass via shares | Med | vault | Fixed, **staged for redeploy** | `0ec0420` |
| M-03 vault/borrower receivable mismatch | Med | vault | **Deferred — design decision** | — |

Tests: `Track1Remediation.t.sol` (10), `PenaltyDoubleCharge.t.sol` (2),
`Track2VaultFixes.t.sol` (5). Full suite **467 passing**, no regressions.

## Live-vault residuals (until redeploy)

The Base/BSC vaults run the pre-fix bytecode until they can be emptied and
`_upgradeVault`-ed (or migrated). During that window:

- **M-09** — a `writeOffBadDebt` followed by a floating repay breaks
  `fixedBorrows <= totalBorrows` with **no on-chain repair** (the only writers are
  the core flows). Treat any bad-debt writeoff on a vault with a fixed leg as the
  trigger to plan that vault's redeploy.
- **M-04** — the LP-share transfer leg is unguarded on the live vault. Blacklist is
  **best-effort** on shares there; the reliable freeze exists only once the fixed
  bytecode ships. Pause does **not** contain it (withdraw stays open by design).
- **M-03** — see below.

## M-03 — deferred pending design (this is the design ticket)

**Root cause.** `TokenVault._pendingInterest` accrues fixed interest continuously
from one aggregate, `fixedRateProduct = Σ(principal·rate)`, at base rate with **no
maturity cap and no penalty**. The borrower's `LibProtocol._outstandingBalance`
caps base at maturity and then accrues *penalty* rate. The vault cannot reconcile
them because it holds no per-loan maturity or penalty data — that lives diamond-side.

**Impact (per review, corrected).** ~5.87% APR LP under-valuation post-maturity
(base over-accrual ~77% offsets omitted penalty), plus a ~0.35% risk-free deposit
sandwich at the repay discontinuity (`_doRepay` floors `totalAccruedInterest` at 0,
so `totalAssets` steps up when a repayment realizes penalty). Medium; partially
self-correcting; sandwich is weak behind Base's sequencer.

**Why deferred.** A wrong change to live share-pricing math is more dangerous than
the Medium it fixes. It is not a mechanical edit (unlike M-09) — it requires giving
the vault maturity/penalty awareness it does not have.

**Design options to decide before implementing:**

1. **Diamond as source of truth (preferred).** The diamond computes exact per-loan
   `_outstandingBalance`; have it drive/reconcile the vault's fixed receivable
   instead of the vault accruing blind. Correct; cost is aggregate maintenance /
   periodic checkpoints + gas.
2. **Maturity-aware vault buckets.** `borrowFixed` records each loan's maturity +
   penalty rate; `_pendingInterest` caps base at maturity and switches to penalty.
   Self-contained but new storage and highest risk (pricing depends on it per block).
3. **Sandwich-only mitigation.** Neutralize the ~0.35% extractable step at the repay
   discontinuity; leave the ~5.87% drift. Smallest, safest; not a true unification.

The design pass must resolve: where the reconciliation lives, gas budget, and how it
interacts with the M-09 cap-and-scale already added to `_doRepay`.

## Structural finding — vaults are not upgradeable

Three accepted Mediums (M-04, M-09, M-03) are un-shippable to a funded vault solely
because `TokenVault` is deployed plain, not behind a proxy. Recommendation: deploy
**future** markets behind a beacon proxy (one diamond-controlled beacon, all vaults
upgrade together), so the next vault-side bug is a one-transaction upgrade rather
than a drain-and-redeploy. Existing deployed vaults cannot be retrofitted — the
proxy has to be there from deployment.
