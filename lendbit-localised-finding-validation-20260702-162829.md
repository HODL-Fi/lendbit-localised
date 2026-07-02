# Finding Validation — lendbit-localised (report 2026-07-02 16:28)

_Validation of `lendbit-localised-pashov-ai-audit-report-20260702-162829.md`
(1 finding + 3 leads)._

Verdicts: `FIXED`, `FALSE POSITIVE`, `ACCEPTED (prior)`.

---

## Findings

| # | Conf | Finding | Location | Verdict | Severity | Action |
|---|------|---------|----------|---------|----------|--------|
| 1 | 85 | Rebasing collateral valued from stale nominal balances | `LibProtocol._getPositionCollateralTokenValue` | ❌ FALSE POSITIVE | Info | None — out-of-scope weird token; **proposed fix is unsafe** |

### 1 — Rebasing collateral stale valuation — FALSE POSITIVE (out of scope) — Info

**Observation is real but out of scope.** `s_positionCollateral` records the nominal
deposit; a *negative-rebasing* collateral would shrink the diamond's real backing while
valuation still uses the stored amount. But this is the weird/rebasing-token class:
collateral listing is `onlySecurityCouncil` and the council is a documented trust
assumption (`scope.md` "Trust assumptions"; `PROTOCOL_SUMMARY.md` lists non-standard
ERC20 behaviour as a known risk surface with "limited coverage," not as supported).
No rebasing token is in scope, and standard 6–18-decimal non-rebasing collateral never
hits this. Per Sherlock AI-21 / Cantina AI-5 / Code4rena AI-3 / BB AI-32, weird tokens
are out of scope unless the README lists them as supported — it does not. Same posture
as the fee-on-transfer disposition (report 2026-07-02 15:06 #1/#6): the resolution, if
such a token were ever considered, is to **reject rebasing collateral at onboarding**,
not to patch the valuation hot path.

**The proposed fix is actively unsafe and is NOT applied.** It rewrites the core
per-position valuation to read `IERC20(_token).balanceOf(address(this))` and haircut by
a global `_liveBacking / _recordedTotal` ratio. Three defects:
1. **Donation-defeatable.** The haircut only fires when `_liveBacking < _recordedTotal`;
   anyone can `transfer` 1 wei of the token to the diamond to push `_liveBacking` back
   up and *remove* the haircut — masking the very undercollateralization it targets.
2. **Cross-position coupling.** The ratio is global but applied to each position's
   `_amount`, so one token's shortfall haircuts *every* holder's health factor at once
   — turning a rebase into a mass wrongful-liquidation trigger.
3. **Manipulable hot path.** `_getPositionCollateralTokenValue` feeds every health
   check and liquidation-eligibility read; making it depend on a live, transiently
   varying `balanceOf` (collateral moves to/from Aave within a tx) makes liquidation
   timing-dependent and grief-able. It would break `property_healthy_position_not_liquidatable`.

No code change to the valuation function. (PoC not written for a rejected fix.)

---

## Leads

| Lead | Location | Verdict | Action |
|------|----------|---------|--------|
| A — Native borrow-token paths inconsistent | `ProtocolFacet.repay` / `LiquidationFacet.liquidatePosition` | 🟡 ACCEPTED (prior) | Dead branch — native is collateral-only (= 2026-07-02 15:06 L11) |
| B — Open-ended liquidation doesn't cap oversized seizure | `LibLiquidation._liquidatePosition` | ✅ FIXED | Mirror `_liquidateLoan` seizure cap |
| C — Anyone can pre-create a position | `PositionManagerFacet.createPositionFor` | 🟡 ACCEPTED (prior) | Design — position vests to `_user` (= 2026-07-02 15:06 #4) |

### Lead A — Native borrow-token paths — ACCEPTED (prior)
Identical to report 2026-07-02 15:06 lead L11. The native `msg.value` branch in
`_allowanceAndBalanceCheck` is unreachable: the native token is registered as
collateral only, borrowable tokens require an ERC4626 vault over an ERC20, and none is
deployed for the native sentinel — so no native borrow (or repay) exists. Documented in
`KNOWN_ISSUES.md §3`. No change.

### Lead B — Open-ended liquidation seizure cap — CONFIRMED → FIXED
`_liquidateLoan` (fixed-term) scales the repayment down when the bonus-adjusted seizure
exceeds the collateral held (the #4a cap); `_liquidatePosition` (open-ended) instead
reverted `INSUFFICIENT_COLLATERAL`. For a deeply-underwater position whose full-debt
seizure exceeds the remaining collateral, every liquidation call reverted unless the
liquidator hand-computed the exact maximum `_amount` — so the collateral could strand
as bad debt. **Fix:** mirror the `_liquidateLoan` cap in `_liquidatePosition` — cap the
seizure to the collateral held and scale `_amount` down proportionally; the pro-rata
`_principalRepaid == 0` guard still fail-closes on true dust. PoCs:
`test_open_ended_liquidation_caps_oversized_seizure` (AuditReport162829) and the updated
`test_liquidation_oversizedSeizure_capsToCollateral` (CovMiscTail, previously asserted
the revert).

### Lead C — Anyone can pre-create a position — ACCEPTED (prior)
Identical to report 2026-07-02 15:06 finding #4. The created position vests to `_user`
(the caller gains nothing), the whitelist gates who can hold a position, and the deposit
paths auto-create internally. The only edge (blocking a would-be transfer recipient) is
covered by the two-step transfer's recipient-consent step. Documented in
`KNOWN_ISSUES.md §2`. No change.

---

## Remediation status (this branch)

**Fixed (with PoC):** Lead B — open-ended liquidation seizure cap
(`LibLiquidation._liquidatePosition`).
**False positive (no change):** Finding #1 — rebasing collateral valuation (out of
scope; proposed fix unsafe).
**Accepted (already documented):** Lead A (= L11), Lead C (= #4).

**Suite:** 433 passing, 0 failing.
