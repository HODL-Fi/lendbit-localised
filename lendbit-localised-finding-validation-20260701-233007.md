# Finding Validation — lendbit-localised (report 2026-07-01 23:30)

_Validation of `lendbit-localised-pashov-ai-audit-report-20260701-233007.md`._
_Note: this review ran against the **already-remediated** code, so several findings
concern the prior fixes (e.g. #2 is the L-1 imprecision flagged in the #4 fix;
#1 is the pooled twin of the #4b skim)._

Verdicts: `CONFIRMED`, `PARTIAL`, `FALSE POSITIVE`, `DESIGN DECISION`.

---

## Validation table

| # | Finding | Location | Verdict | Severity | Remediation |
|---|---------|----------|---------|----------|-------------|
| 1 | Open-ended liquidations drain collateral without reducing principal | `LibLiquidation._liquidatePosition` | ✅ CONFIRMED | High | **Fixed** — pro-rata allocation |
| 2 | Partial fixed-loan liquidation forgives accrued interest | `LibLiquidation._liquidateLoan` | ✅ CONFIRMED | Medium | **Fixed** — no anchor reset |
| 3 | Liquidation eligibility ignores collateral LTV | `LibLiquidation._isLiquidatable` | 🟡 DESIGN (valid) | Info | **Implemented** — configurable per-asset threshold |
| 4 | Fee-on-transfer deposits overstate vault principal | `LibVaultManager._deposit` | ✅ CONFIRMED | Low | **Fixed** — credit second-hop receipt |
| 5 | Floating debt retroactively repriced after rate changes | `LibProtocol._calculateUserDebt` | ⚠️ PARTIAL | Low | Accepted-design-adjacent |
| 6 | Fee-on-transfer borrow assets unrepayable | `LibProtocol._repay` | ❌ FALSE POSITIVE | Info | None (intentional guard) |
| 7 | Initial vault config bypasses liquidation-bonus bounds | `LibVaultManager._deployVault` | 🟡 DESIGN (admin) | Low/QA | **Fixed** — bounds at deploy+upgrade |
| 8 | Existing blacklisted users can still deposit | `LibVaultManager._deposit` | ✅ CONFIRMED | Low | **Fixed** — whitelist gate on deposit |

---

## Per-finding notes

### 1 — Open-ended liquidation interest-only skim — CONFIRMED, High — FIXED
The pooled twin of the fixed-loan skim fixed earlier (#4b). `_liquidatePosition` used
interest-first `_repayStateChanges`, so paying exactly the accrued interest gave
`_principalRepaid == 0`: the liquidator seized `interest·(1+bonus)` collateral while
principal and the vault borrow tally stayed put. Repeatable each block as interest
re-accrues (`s_positionBorrowedLastUpdate` reset makes same-tx repeat impossible, but
per-block drain is real) → collateral drained, principal left as bad debt.
**Fix:** inlined pro-rata allocation in `_liquidatePosition`
(`_principalRepaid = _amount * principalOutstanding / totalDebt`, revert on 0),
mirroring `_liquidateLoan`; also clamps `_amount` to total debt (kills a pre-existing
`_totalDebt - _amount` underflow). `_repayStateChanges` keeps interest-first for
ordinary `_repay`. Test: `testLiquidatePosition_cannotSkimInterestOnly`.

### 2 — Partial fixed-loan liquidation forgives interest — CONFIRMED, Medium — FIXED
`_liquidateLoan` reset `_loan.startTimestamp` after a pro-rata partial, forgiving the
accrued base interest on the surviving principal and stranding the matching LP
receivable in the vault's `totalAccruedInterest` (share-price overstatement). Because
base interest is linear in principal and keyed on `startTimestamp` (penalty is anchored
to the immutable `s_loanStartTime`, unaffected), **not** resetting the anchor yields
exactly the correct remaining debt and re-backs the vault receivable.
**Fix:** removed the anchor reset from `_liquidateLoan` (moot on full repayment — loan
closes). Test: `testLiquidateLoan_partial_retains_accrued_interest`; updated
`testLiquidateLoanPartial_Success` (debt now = remaining principal + retained interest).

### 3 — Liquidation ignores collateral LTV — CONFIRMED gap, PROPOSED FIX UNSAFE — Medium — OPEN
Borrow health uses LTV-weighted collateral (`_getPositionUtilizableCollateralValue`),
liquidation uses **raw** collateral at a flat 90% (`_getPositionCollateralValue`). For a
low-LTV collateral the position can go deep underwater before it's liquidatable. Real,
but latent (needs a low-LTV collateral configured; defaults are ~80%). The report's fix
(utilizable @ 90%) would make max-LTV **healthy** positions instantly liquidatable —
breaks `property_healthy_position_not_liquidatable`. Correct remediation is a per-asset
liquidation threshold strictly between the asset's LTV and 100% of raw — a design
decision, not a drop-in patch. **Held pending a design call.**

### 4 — FoT deposit overstates principal — CONFIRMED, Low — OPEN
`_config.totalDeposits += _received` credits the first-hop (user→diamond) receipt while
the vault may receive less on the second hop, inflating the utilization cap. Shares are
still correct (vault snapshots its own delta). FoT is out of scope / admin-gated (Low).
Fix: credit `totalDeposits` from the vault's second-hop balance delta.

### 5 — Floating debt repricing / LP underfunding — PARTIAL, Low — ACCEPTED-ADJACENT
Root cause is the **accepted** KNOWN_ISSUES governance-repricing item. On a rate *cut*,
the vault keeps the old-rate accrual for the pre-change interval (`setInterestRate`
accrues first) while borrowers reprice the whole interval at the new lower rate →
`totalAccruedInterest` over-booked, borne by tail LPs. Distinct un-documented
consequence, but gated on the "set-once rate" premise. Proper fix = per-position borrow
index (already deferred). Recommend documenting in KNOWN_ISSUES or implementing the index
if rates will move.

### 6 — FoT borrow unrepayable — FALSE POSITIVE — Info
The `_received != _amount` check is an **intentional fail-closed FoT rejection** (added
as the remediation of a prior #6; comments say "fail closed"). The report's fix would
reinstate the over-crediting bug it prevents. Only real note: deposit tolerates FoT while
repay rejects it — resolve by rejecting FoT at onboarding, not loosening the repay guard.

### 7 — Deploy/upgrade bypasses bonus bounds — DESIGN (admin) — Low/QA — OPEN
`_deployVault` **and** `_upgradeVault` store `liquidationBonus`/`reserveFactor` without
the setter's bounds (`bonus ≤ 1000`; reserveFactor ≤ 100% is enforced in
`TokenVault.setReserveFactor` but not the constructor). Council-only, trusted → admin
footgun. Valid defense-in-depth: mirror the setter bounds at both deploy and upgrade.

### 8 — Blacklisted existing user can deposit — CONFIRMED, Low — OPEN
`_deposit`/`_withdraw` have no whitelist gate; only the create-new-position branch checks
it, so an existing-position user blacklisted later can still mint vault shares. Collateral
and borrow paths gate on every call. Self-participation only (Low). Fix: add
`_callerWhitelisted(s)` to `_deposit` (mirror `_depositCollateral`).

---

## Remediation status (this branch)

**Fixed:**
- **#1** — pro-rata allocation inlined in `LibLiquidation._liquidatePosition`
  (+ `_amount` clamp to total debt). Test `testLiquidatePosition_cannotSkimInterestOnly`.
- **#2** — removed the `startTimestamp` reset from `LibLiquidation._liquidateLoan`.
  Tests `testLiquidateLoan_partial_retains_accrued_interest`; updated
  `testLiquidateLoanPartial_Success`.

- **#4** — `LibVaultManager._deposit` now credits `totalDeposits` from the vault's
  actual second-hop balance delta (`_vaultReceived`), not the diamond's first-hop
  receipt, so a fee-on-transfer token can't inflate the utilization cap. Updated
  `WeirdTokenDeposit.test_fee_on_transfer_credits_received_not_nominal` to assert
  `totalDeposits == real vault balance`.
- **#7** — added `_validateVaultConfigBounds` (bonus ≤ 1000, reserveFactor ≤ 100%)
  enforced in **both** `_deployVault` and `_upgradeVault`, matching the in-place
  setters. Tests: `test_deployVault_rejects_excessive_liquidationBonus` /
  `_rejects_excessive_reserveFactor` / `_accepts_bounded_config`.
- **#8** — `LibVaultManager._deposit` now calls `_addressIsWhitelisted(_from)` on
  every deposit (not just position creation), so a blacklisted existing-position
  user can no longer mint shares. Test: `test_vaultDeposit_blocked_after_blacklist`.

- **#3** — reclassified as a **valid design decision, not a bug**: the flat 90%
  liquidation threshold on raw collateral is the *solvency* ceiling calibrated so
  `threshold (90%) + max bonus (10%) ≤ 100%` of raw value, while per-asset LTV is
  the separate *origination* limit. A liquidation is always solvent-with-margin
  regardless of LTV, so the "dead zone" is not a bad-debt path (worked example in
  chat). The report's proposed fix (threshold = LTV-weighted value) would liquidate
  healthy max-borrow positions and is NOT applied.
  Nonetheless, to keep the option open, the flat threshold was made a **configurable
  per-asset knob**: new storage `s_collateralLiquidationThreshold` (0 → 90% default,
  so behaviour is byte-for-byte unchanged), `setCollateralLiquidationThreshold`
  (council-only, enforces `LTV ≤ threshold ≤ 100%` so the healthy-not-liquidatable
  invariant is preserved), `getCollateralLiquidationThreshold`, and
  `_isLiquidatable` now compares debt against Σ(collateralValue · perAssetThreshold).
  Tests: `LiquidationThreshold.t.sol` (default 90%, setter bounds, council-only,
  dead-zone flip on tightening).

**Suite:** 421 passing, 0 failing.

**No action:** #5 (accepted-design-adjacent — document), #6 (false positive).
