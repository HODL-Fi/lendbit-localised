# Finding Validation — lendbit-localised (report 2026-07-02 18:17)

_Validation of `lendbit-localised-pashov-ai-audit-report-20260702-181747.md`
(9 findings + 11 leads). Cross-checked against the three prior reviews; most items
are re-reports of already-dispositioned findings. Four are genuinely new or
complete a partial prior fix._

Verdicts: `FIXED`, `FALSE POSITIVE`, `ACCEPTED / DUPLICATE`.

---

## Findings table

| # | Conf | Finding | Location | Verdict | New? | Action |
|---|------|---------|----------|---------|------|--------|
| 1 | 95 | Blacklisted LPs can still withdraw vault assets | `LibVaultManager._withdraw` | ✅ CONFIRMED | **NEW** | **Fixed** — whitelist gate on withdraw |
| 2 | 92 | Zero-amount borrows reset interest accrual | `LibProtocol._borrow` | ✅ CONFIRMED | **NEW** | **Fixed** — reject `_amount == 0` |
| 3 | 90 | Bad-debt writeoff leaves utilization denominator stale | `LibVaultManager._writeOffBadDebt` | ✅ CONFIRMED | **PARTIAL** | **Fixed** — decrement `totalDeposits` (denominator) |
| 4 | 88 | Fee-on-transfer borrow tokens irrepayable | `TokenVault._doBorrow` | ❌ FALSE POSITIVE | dup | None — intentional fail-closed FoT guard |
| 5 | 87 | Coarse-decimal collateral rounds seizure to zero | `LibLiquidation._getAmountToLiquidate` | 🟡 ACCEPTED | dup | Documented (15:06 #5) |
| 6 | 85 | Interest-rate changes retroactively reprice debt | `LibProtocol._setInterestRate` | 🟡 ACCEPTED | dup | Documented (KNOWN_ISSUES §2) |
| 7 | 84 | Reserve-factor changes re-split historical interest | `TokenVault.setReserveFactor` | 🟡 ACCEPTED | **NEW angle** | Documented (KNOWN_ISSUES §2, same root cause as #6) |
| 8 | 82 | Liquidations depend on synchronous Aave liquidity | `LibYieldStrategy._rebalanceForWithdrawal` | 🟡 ACCEPTED | dup | Documented (15:06 L6) |
| 9 | 80 | Anyone can consume a whitelisted user's position slot | `PositionManagerFacet.createPositionFor` | ✅ CONFIRMED | re-flagged | **Fixed** — restrict to self / council (upgraded from prior "accepted") |

---

## New / actionable — per-finding notes

### 1 — Blacklisted LPs can still withdraw — CONFIRMED (new), Low — FIXED
Distinct from the prior deposit-side blacklist finding (233007 #8, fixed) and from the
15:06 L5 change (which removed the *token-support* gate so LPs aren't trapped by a
*token* pause). This is the *user*-blacklist axis: `_withdraw` was the only
value-extracting user path with no whitelist gate — deposit, collateral withdrawal
(`_positionIdCheck → _callerWhitelisted`), and `claimYield` (15:06 L8) all gate it. A
user blacklisted after depositing could still burn shares and pull vault assets,
defeating the freeze. **Fix:** `s._addressIsWhitelisted(_to)` in `_withdraw`. Composes
with L5 (a *whitelisted* LP still withdraws during a token-support pause). PoC:
`test_blacklisted_lp_cannot_withdraw`.

### 2 — Zero-amount borrows reset interest accrual — CONFIRMED (new), Low — FIXED
`_borrow` had no `_amount == 0` guard (unlike `_takeLoan`, which we added one to in the
2026-07-01 round). `_doBorrow` also has no zero-check and `safeTransfer(receiver, 0)`
does not revert, so `borrow(token, 0)` succeeded, recomputing `s_positionBorrowed` and
resetting `s_positionBorrowedLastUpdate`. Spamming it while the per-call accrued
interest rounds below one token unit lets a small borrower checkpoint away interest.
Bounded impact (dust, small debt, per-block gas cost), but a clean consistency gap.
**Fix:** `if (_amount == 0) revert AMOUNT_ZERO();` in `_borrow`. PoC:
`test_zero_amount_borrow_reverts`.

### 3 — Bad-debt writeoff leaves utilization DENOMINATOR stale — CONFIRMED (completes 15:06 #3) — FIXED
The 15:06 #3 fix decremented the utilization **numerator** (`config.totalBorrows`).
This report correctly notes the **denominator** (`config.totalDeposits`) is also left
inflated: socialized bad debt is capital that left the vault and won't return, so the
real deposit base shrank. Leaving `totalDeposits` high makes `_validateVaultUtlization`
read utilization too low and admit a new borrow above the true 90% cap of *liquid*
assets. **Fix:** in `_writeOffBadDebt`, also reduce `totalDeposits` by the principal
portion of the write-off (`min(_amount, totalBorrows)` captured before
`_updateVaultRepays`), floored at zero. Now `available = (deposits − loss) −
(borrows − loss)` tracks the vault's real liquid balance. PoC:
`test_writeOffBadDebt_reduces_totalDeposits` (asserts both counters drop).

### 9 — createPositionFor griefing — CONFIRMED, Low — FIXED (upgraded)
Flagged in three reviews (15:06 #4, 16:28 Lead C, now 18:17 #9). Previously dispositioned
as accepted design; on the third flag, and with a clean non-breaking fix available, it
is now fixed. The concrete edge is real: an attacker pre-creates a whitelisted victim's
single position slot, so when a pending position **transfer** targets that victim, the
`accept` reverts `ADDRESS_EXISTS` — a griefing DoS on the transfer feature. **Fix:**
restrict `createPositionFor` to `msg.sender == _user || msg.sender == contractOwner()`.
This preserves self-service and council-run onboarding (the deposit paths still
auto-create for the depositor), blocks arbitrary callers, and breaks no existing caller
(all test/deploy callers are the owner or the user themselves). New error
`UNAUTHORIZED_POSITION_CREATION`. PoCs: `test_createPositionFor_rejects_arbitrary_caller`,
`test_createPositionFor_allows_self_and_council`.

---

## Duplicates / accepted — per-finding notes

### 4 — FoT borrow irrepayable — FALSE POSITIVE (dup of 15:06 #1 / 233007 #6)
The `_received == _amount` closeout guard is the intentional fail-closed FoT rejection;
the proposed "book received amount" fix reintroduces the over-crediting it prevents.
Token listing is council-only, no FoT token is in scope. Documented in KNOWN_ISSUES §2.

### 5 — Coarse-decimal collateral rounds seizure to zero — ACCEPTED (dup of 15:06 #5)
Identical. A round-up "fix" would over-seize a whole high-value 0-decimal unit for a
dust repayment, so the fail-closed revert is retained; resolution is onboarding
restriction. Documented in KNOWN_ISSUES §2.

### 6 — Interest-rate retroactive repricing — ACCEPTED (dup of 233007 #5)
The governance-repricing accepted design (fixed-rate deployment, set-once posture).
Already documented in KNOWN_ISSUES §2 with the rate-cut LP consequence.

### 7 — Reserve-factor re-split — ACCEPTED (new angle, same root cause as #6)
Real accounting divergence: `_accrueInterest` books the LP receivable net of the
per-interval factor, but `_doRepay` re-splits the whole `interestPaid` at the *current*
factor, so a mid-stream `setReserveFactor` drifts `totalAccruedInterest` /
`totalProtocolReserve` from cash. Same root cause as #6 (no accrual-time bucketing /
borrow-index) and same posture: council-only (`onlySecurityCouncil`, trusted),
set-once-parameter operational assumption. **Newly documented** in KNOWN_ISSUES §2
alongside the rate case; the real remedy is to bucket gross interest into LP/protocol
receivables at accrual time.

### 8 — Liquidation depends on Aave liquidity — ACCEPTED (dup of 15:06 L6)
External-dependency risk; operational mitigation is `setYieldPause` (skips the Aave
unwind, seizes liquid collateral). Documented in KNOWN_ISSUES §3.

---

## Leads — all duplicates / by-design / dust (no new action)

- **Router rotation strands callbacks** (`_handleOracleFulfillment`) — admin router
  rotation invalidates in-flight requests; council-only, observability-only (the
  Functions `priceData` does not feed lending valuation). Info.
- **Yield pause can block exits** — same as Finding #8 / 15:06 L6. Documented.
- **Exact-receipt repayment completes fee-token failure** — the repay side of Finding #4
  (intentional FoT fail-closed). Documented.
- **Overdue penalties reappear after partial repayment** (`_repayLoanFor`) —
  **working as intended**: the penalty is deliberately anchored to the immutable maturity
  (`s_loanStartTime`), so resetting the base-interest anchor `startTimestamp` does not
  move it (2026-07-01 #6 design). Not a bug.
- **Interest base drift after partial liquidation** (`_calculateUserDebt`) — the
  open-ended pooled model capitalizes interest into `s_positionBorrowed` by design;
  documented accrual behaviour, not a divergence.
- **Vault accrual loses fractional interest** (`_accrueInterest`) — sub-unit rounding;
  dust (same class as the yield-dust lead). Info.
- **Tiny yield increments become dust** (`_accrueYield`) — dup of 15:06 L12
  (RAY-scaled index; unreachable at realistic principal). Documented.
- **Pre-clamp liquidation validation stricter than final transfer** (`_liquidationCheck`)
  — the allowance/balance check runs on the pre-clamp `_amount`, i.e. it is *stricter*
  than needed (liquidator ends up paying ≤ that). Benign; no under-check. Info.
- **Packed signature encoding** (`_verifyBorrowSignature`) — `abi.encodePacked` with a
  single leading dynamic `action` string (a constant `"BORROW_REQUEST"` in practice)
  followed by fixed-width fields; no adjacent-dynamic ambiguity and the signer is
  trusted, so no practical collision. Recommend `abi.encode`/EIP-712 as defense-in-depth
  (deferred — breaking change to the off-chain signer format). Info.
- **Native sentinel enters ERC20 vault paths** — native is collateral-only; a vault over
  the native sentinel would fail at construction/transfer. Related to the native-repay
  dead branch (15:06 L11). Info.
- **Aave withdraw return ignored** (`_withdraw`) — dup of 15:06 L7 (concrete-amount
  withdraw is exact for standard Aave; balance re-read after). Documented.

---

## Remediation status (this branch)

**Fixed (with PoCs in `test/audit/AuditReport181747.t.sol`):**
- **#1** — `_withdraw` whitelist gate (blacklisted LP freeze).
- **#2** — `_borrow` rejects `_amount == 0`.
- **#3** — `_writeOffBadDebt` decrements `totalDeposits` (utilization denominator).
- **#9** — `createPositionFor` restricted to self / council.

**Newly documented (accepted design):** #7 (reserve-factor re-split, KNOWN_ISSUES §2).
**Duplicates of prior dispositions:** #4, #5, #6, #8 + all 11 leads.

**Suite:** 438 passing, 0 failing.
