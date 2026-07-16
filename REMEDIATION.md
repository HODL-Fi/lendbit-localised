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
| M-03 vault/borrower receivable mismatch | Low (accepted) | vault | **Accepted — no code change** | — |

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
- **M-03** — accepted as Low, see below (no code change; not a residual that needs
  a redeploy).

## M-03 — accepted as Low (no code change)

**Decision (team, this remediation round).** Two facts settle it:

1. **No LP ever receives less than base.** The vault accrues at least the base rate
   on outstanding principal continuously (`TokenVault._pendingInterest`), even past
   maturity — it never credits less than base. Every M-03 number is measured against
   a *penalty-inclusive* receivable, so the "under-valuation" is about penalty
   (extra), never the base yield LPs signed up for.
2. **Penalty may be shared LP/protocol.** Current behavior — `_doRepay` splits the
   repaid interest+penalty by `reserveFactor` (~protocol cut) with the remainder to
   LPs — is intended and acceptable.

Under those two facts the "~5.87% APR under-valuation" is **not a harm**: it is a
benign timing effect that redistributes penalty *upside* by holding time (an LP who
exits mid-overdue forgoes penalty not yet booked; whoever holds at repayment gets
it) and self-corrects at repayment. No principal or base yield is ever at risk.

**Residual (accepted).** The penalty lands as a discrete step at repayment rather
than accruing smoothly, so a depositor could sandwich a repayment (deposit before,
withdraw after) to skim ~0.35% of the penalty step from sitting LPs. It needs
mempool visibility (weak behind Base's sequencer) and skims penalty upside, never
anyone's base. Accepted as Low — not worth a redesign of live share-pricing math.

**If ever revisited (optional, not scheduled).** The only proportionate change is to
stop the penalty step from being instantaneously capturable (sandwich-only
mitigation). The full accrual redesign (diamond-driven, or maturity-aware vault
buckets) is not warranted for a benign timing effect.

## Structural finding — vaults are not upgradeable

Three accepted Mediums (M-04, M-09, M-03) are un-shippable to a funded vault solely
because `TokenVault` is deployed plain, not behind a proxy. Recommendation: deploy
**future** markets behind a beacon proxy (one diamond-controlled beacon, all vaults
upgrade together), so the next vault-side bug is a one-transaction upgrade rather
than a drain-and-redeploy. Existing deployed vaults cannot be retrofitted — the
proxy has to be there from deployment.
