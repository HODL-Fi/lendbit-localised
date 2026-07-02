# Finding Validation — lendbit-localised (report 2026-07-02 15:06)

_Validation of `lendbit-localised-pashov-ai-audit-report-20260702-150619.md`._
_This review ran against the code after the 2026-07-01 remediation rounds. Two
findings (#1, #6) re-report the intentional fail-closed FoT guard already
dispositioned as a false positive in the prior review; three are genuine fixes._

Verdicts: `CONFIRMED`, `FALSE POSITIVE`, `DESIGN DECISION`.

---

## Validation table

| # | Conf | Finding | Location | Verdict | Severity | Remediation |
|---|------|---------|----------|---------|----------|-------------|
| 1 | 95 | Fee-on-transfer borrow assets create unrepayable debt | `LibProtocol._repay/_repayLoanFor/_liquidate*` | ❌ FALSE POSITIVE | Info | None — intentional fail-closed guard; reject FoT at onboarding |
| 2 | 92 | Collateral LTV can exceed liquidation threshold | `LibProtocol._addCollateralToken/_setCollateralTokenLtv` | ✅ CONFIRMED | Low | **Fixed** — enforce `LTV ≤ effective threshold` in both setters |
| 3 | 90 | Bad-debt writeoff leaves utilization borrow accounting stale | `LibVaultManager._writeOffBadDebt` | ✅ CONFIRMED | Medium | **Fixed** — mirror the write-off in `config.totalBorrows` |
| 4 | 88 | Arbitrary callers can occupy another user's position slot | `PositionManagerFacet.createPositionFor` | 🟡 DESIGN | Low | Documented — intentional onboarding affordance, position vests to `_user` |
| 5 | 86 | Coarse collateral can become liquidatable but unliquidatable | `LibLiquidation._getAmountToLiquidate` | 🟡 EDGE (accepted) | Low | Documented — round-up fix risks over-seizure; restrict onboarding instead |
| 6 | 83 | Fee-on-transfer collateral breaks liquidation incentives | `LibLiquidation._getAmountToLiquidate/_transferToken` | ❌ FALSE POSITIVE | Info | None — weird token, liquidator opts in; reject FoT at onboarding |
| 7 | 75 | Cross-user borrow nonces share one global namespace | `LibProtocol._requestBorrow` | ✅ CONFIRMED | Low | **Fixed** — key replay protection by wallet, not `contractAddress` |

---

## Per-finding notes

### 1 — FoT borrow unrepayable — FALSE POSITIVE — Info
Duplicate of report-2 (2026-07-01 23:30) finding #6. The `_received != _amount`
assertion on every repay/liquidation closeout is a deliberate fail-closed rejection
of fee-on-transfer borrow tokens: crediting the smaller received amount (the report's
proposed fix) would let a borrower discharge debt the LPs never received —
reintroducing the over-crediting bug the guard prevents. Token listing is
council-only and no FoT token is in scope. The only real note is the asymmetry
(deposit tolerates FoT, closeout rejects it); the correct resolution is to reject FoT
at onboarding, not to loosen the guard. Documented in KNOWN_ISSUES §2.

### 2 — Collateral LTV can exceed liquidation threshold — CONFIRMED, Low — FIXED
The LTV setters enforced only a 10% floor, no ceiling against the liquidation
threshold. The threshold setter (`_setCollateralLiquidationThreshold`) already
enforces `threshold ≥ LTV`, but the LTV setters did not enforce the mirror, so an
admin could set `LTV > threshold` and let a borrower open a position at `LTV·C` that
is already past the `threshold·C` liquidation trigger — healthy on origination yet
immediately liquidatable, breaking `property_healthy_position_not_liquidatable`.
Admin-only (Low/QA), but the invariant is load-bearing and was already half-enforced,
so closing the mirror is legitimate defense-in-depth.
**Fix:** `_addCollateralToken` bounds LTV to the protocol default threshold (90%, what
the token is defaulted to); `_setCollateralTokenLtv` bounds it to the *live effective*
threshold so it composes with the per-asset knob. New error
`LTV_ABOVE_LIQUIDATION_THRESHOLD(ltv, threshold)`. Tests:
`test_addCollateralToken_rejects_ltv_above_threshold`,
`test_setCollateralTokenLtv_rejects_ltv_above_threshold`,
`test_ltv_setter_composes_with_threshold_widening`.

### 3 — Bad-debt writeoff leaves utilization stale — CONFIRMED, Medium — FIXED
`_writeOffBadDebt` called `TokenVault.updateBadDebt` (which clears the unrecoverable
principal from the vault's internal `totalBorrows`) but left
`s_tokenVaultConfig[_token].totalBorrows` — the counter `_validateVaultUtlization`
reads — untouched. After a bad-debt event is socialized, the config counter stays
inflated by the written-off principal → utilization is permanently high → new borrows
revert `TOKEN_OVERUTILIZATION`, and there is no other path to decrement it. This is a
real stuck-state DoS of the core borrow path, triggered by an ordinary post-liquidation
writeoff.
**Fix:** `_writeOffBadDebt` now also calls `_updateVaultRepays(s, _token, _amount)`,
which floors at zero (so an interest-inclusive `_amount` cannot underflow). Test:
`test_writeOffBadDebt_reduces_config_totalBorrows`.

### 4 — createPositionFor for arbitrary user — DESIGN — Low — DOCUMENTED
`createPositionFor(_user)` is callable by anyone, but the created position vests to
`_user` (not the caller), the whitelist gates who can hold a position at all, and the
deposit paths auto-create internally — so pre-creation grants the caller nothing. The
only concrete edge (pre-creating a position for a would-be *transfer recipient*,
blocking it on `ADDRESS_EXISTS`) is already covered by the two-step transfer's
recipient-consent step. A `msg.sender == _user` restriction would break the intended
operator/relayer onboarding flow (and 25 existing tests rely on cross-address
creation). Left open by design; documented in KNOWN_ISSUES §2.

### 5 — Coarse collateral round-to-zero seizure — EDGE — Low — DOCUMENTED
`_getAmountToLiquidate` floors the USD→collateral conversion to integer units before
the bonus, so if a position's entire remaining debt maps to `< 1` unit of a 0-decimal,
very-high-priced collateral, seizure rounds to zero and the liquidation reverts
(fail-closed → the residual becomes bad debt). Needs a non-standard 0-decimal
council-listed collateral and sub-unit residual debt. The report's round-*up* fix is
unsafe — it would seize a whole high-value unit for a tiny repayment (over-liquidation)
— so the fail-closed behaviour is retained and the resolution is to not list 0-decimal
high-value tokens as collateral. Documented in KNOWN_ISSUES §2. (Same class as the
earlier adversarial-review "L-2 dust-collateral un-liquidatability" lead.)

### 6 — FoT collateral liquidation incentive — FALSE POSITIVE — Info
On liquidation the seized collateral is transferred nominally; a fee-on-transfer
collateral delivers the liquidator slightly under the bonus-adjusted amount. Internal
accounting stays consistent (position collateral is debited by the same nominal amount
transferred), there is no protocol loss, and the liquidator opts in with full knowledge
of the token. Weird-token / out-of-scope class (same disposition as #1). Resolution:
reject FoT collateral at onboarding.

### 7 — Cross-user borrow nonces share one global namespace — CONFIRMED, Low — FIXED
`s_requestBorrowNonceUsed` was keyed by `_request.contractAddress`, which is pinned to
`address(this)` — a single global namespace. If the off-chain signer issues
wallet-local nonces, one wallet consuming nonce N blocks every other wallet's
legitimate nonce-N request. The signature binds the wallet, so per-wallet keying is
strictly safe and removes the coupling.
**Fix:** key replay protection by `_request.wallet`. Same (wallet, nonce) replay is
still blocked; the existing reused-nonce test (`testRequestBorrowFailsForReusedNonce`)
still passes. Test: `test_requestBorrow_nonce_is_per_wallet`.

---

## Remediation status (this branch)

**Fixed (with PoCs in `test/audit/AuditReport0702.t.sol`):**
- **#2** — `LTV ≤ effective liquidation threshold` enforced in `_addCollateralToken`
  and `_setCollateralTokenLtv`; new error `LTV_ABOVE_LIQUIDATION_THRESHOLD`.
- **#3** — `_writeOffBadDebt` mirrors the write-off into `config.totalBorrows` via
  `_updateVaultRepays`.
- **#7** — request-borrow nonce namespace keyed by wallet, not `contractAddress`.

**Documented (no code change):**
- **#1 / #6** — intentional fail-closed FoT guard; reject FoT at onboarding.
- **#4** — `createPositionFor` open onboarding affordance (position vests to `_user`).
- **#5** — coarse 0-decimal collateral dust edge; restrict onboarding, don't round up.

**Suite:** 426 passing, 0 failing.
