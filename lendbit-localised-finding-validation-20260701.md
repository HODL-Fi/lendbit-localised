# Finding Validation — lendbit-localised

_Validation of `lendbit-localised-pashov-ai-audit-report-20260701-161819.md`, 2026-07-01._

Each finding was traced against the code by a dedicated validation pass. Verdicts:
`CONFIRMED` (real), `PARTIAL` (real but mis-scoped / fix incomplete),
`FALSE POSITIVE`, `DESIGN DECISION` (documented / accepted).

---

## Validation table

| # | Finding | Location | Verdict | Severity | Remediation |
|---|---------|----------|---------|----------|-------------|
| 1 | User whitelist can spend the Chainlink subscription | `PriceOracleFacet.sendRequest` | ✅ CONFIRMED | Medium | **Fixed** — dedicated keeper allowlist |
| 2 | Zero-principal fixed loans can make liquidation unbounded | `LibProtocol._takeLoan` | ✅ CONFIRMED | Medium | **Fixed** — zero-principal guard + per-position loan cap |
| 3 | Liquidations can be forced to leave open-ended bad debt | `LibLiquidation._liquidatePosition` | ❌ FALSE POSITIVE | Info | None — revert is a safety guard |
| 4 | Fixed-loan liquidation has two collateral-draining paths | `LibLiquidation._liquidateLoan` | ⚠️ PARTIAL | Medium | **Fixed** — seizure cap + pro-rata allocation |
| 5 | Positions can be forced onto whitelisted recipients | `PositionManagerFacet.transferPositionOwnership` | ✅ CONFIRMED | Medium | **Fixed** — two-step (pull) transfer |
| 6 | Blacklisted wallets can still receive signed cross-chain borrows | `LibProtocol._requestBorrow` | ⚠️ PARTIAL | Low | **Fixed** — whitelist check on wallet |
| 7 | Removing collateral support can make solvent users liquidatable | `LibProtocol._removeCollateralToken` | ✅ CONFIRMED | Medium | **Fixed** — block delist while held |
| 8 | Rate changes retroactively reprice open-ended borrower debt | `LibProtocol._calculateUserDebt` | 🟡 DESIGN DECISION | Low/Info | Accepted (KNOWN_ISSUES) |
| 9 | Fixed-loan principal accrues in the vault at the mutable global rate | `TokenVault._pendingInterest` | ✅ CONFIRMED | Medium | **Fixed** — per-rate fixed-loan accrual |

---

## Per-finding notes

### 1 — Whitelist can spend the Chainlink subscription — CONFIRMED, Medium
`sendRequest` gated on `s.isWhitelisted[msg.sender]` — the **general** borrower/depositor
whitelist (owner-admitted via `PositionManagerFacet.whitelistAddress`), not a keeper list.
Any whitelisted user could loop `sendRequest` to drain the protocol's LINK subscription
(no rate limit). Griefing, not attacker-profit; the Functions response isn't read by core
pricing math, so no oracle-manipulation blast radius.

### 2 — Zero-principal fixed loans → liquidation DoS — CONFIRMED, Medium
`_takeLoan` never rejected `_principal == 0` (while `_requestBorrow` does). A zero-debt loan
is pushed `FULFILLED` and is **permanent** — it can't be repaid or liquidated — so it sits in
`s_positionActiveLoanIds` forever. `_totalActiveDebt` walks that array on every health /
liquidation check (O(N)), so array bloat can push liquidation past the block gas limit →
permanent unliquidatability → bad debt borne by LPs. The zero check removes the unprunable
class; the per-position cap bounds the loop for many *non-zero* loans too.

### 3 — Liquidations forced to leave bad debt — FALSE POSITIVE, Info
The `INSUFFICIENT_COLLATERAL` revert is a safety guard: a liquidator can always pick a smaller
`_amount` (linear, no interest floor in `_liquidatePosition`). Debt is reduced by exactly the
repaid amount (`_repayStateChanges`); residual is inherent undercollateralization + bonus, not
created by the revert. The proposed "cap seizure" fix changes nothing economically.

### 4 — Fixed-loan liquidation draining paths — PARTIAL, Medium
- **4(a)** genuine DoS: interest-floor (`_liquidateLoan:88`) + seizure-revert (`:70`) mean a
  deeply-overdue loan where `interestDue·(1+bonus) > collateral` cannot be liquidated at any
  valid `_amount` → permanent bad debt. The report's cap-only fix is **incomplete** — the
  interest floor must also be relaxed.
- **4(b)** CONFIRMED: interest-only liquidation with `_principalRepaid == 0` is **same-tx
  repeatable** because `_outstandingBalance` ignores `_loan.repaid` — a liquidator drains all
  collateral as "interest" while principal stays as bad debt. `require(_principalRepaid > 0)`
  fixes 4(b) only.

### 5 — Positions forced onto whitelisted recipients — CONFIRMED, Medium
`transferPositionOwnership` (owner-of-position gated) moves a position with no recipient
consent; debt/collateral are keyed by `positionId` and follow the transfer. Calibrated to
Medium: debt is **non-recourse** (victim loses funds only if they later deposit into the
inherited position), the whitelisted-with-no-position window is narrow, and the attacker burns
their own whitelist to do it. Fix: two-step (pull) accept, à la Ownable2Step; keep the admin
force-transfer path exempt.

### 6 — Blacklisted wallets receive signed borrows — PARTIAL, Low
Real omission: `_requestBorrow` never checks `isWhitelisted[_request.wallet]` (the local path
does). But the authorization is the signature from `s_requestBorrowSigner`, and nonces are
single-use, so exploitation needs a pre-signed, unused, unexpired request surviving into the
blacklist window. Defense-in-depth / path-consistency, not a fund drain. **Not** covered by
KNOWN_ISSUES. The one-line whitelist check is a correct, cheap fix.

### 7 — Removing collateral support → solvent users liquidatable — CONFIRMED, Medium
`_removeCollateralToken` swap-removes the token from `s_allCollateralTokens` (so valuation
loops count it as **zero**) but leaves user balances and the live price feed (feed-delete is
commented out). Permissionless liquidators then seize the delisted token at full price + bonus
against users who were solvent pre-removal. Delisting is a normal admin op (not in the trusted-
footgun list), so the "admin unknowingly breaks assumptions" exception applies. Fix needs a
maintained per-token collateral counter (or soft-delist that keeps valuing existing holdings).

### 8 — Rate changes retroactively reprice open debt — DESIGN DECISION, Low/Info
Mechanism confirmed (`_calculateUserDebt` applies current global `s_interestRate` over the
whole elapsed interval), but explicitly accepted in KNOWN_ISSUES and self-consistent for pooled
debt (vault + borrower both use the current rate → no value gap). The report's proposed fix
references `s_positionBorrowRate`, **which does not exist** in storage.

### 9 — Fixed-loan principal accrues at the mutable global rate — CONFIRMED, Medium
Distinct real leak, **not** in KNOWN_ISSUES. Fixed loans repay at immutable
`Loan.annualRateBps`, but the vault accrues one `totalBorrows` scalar at the mutable
`interestRate` (`TokenVault._pendingInterest`). A rate increase inflates the ERC4626 share
price with interest that fixed-loan borrowers will never pay; early LP withdrawers extract it
from remaining LPs. Fix: segregate fixed-loan principal and accrue each tranche at its own
rate.

---

## Remediation status (this branch)

**Fixed:**

- **#1** — added a dedicated keeper allowlist (`LibAppStorage.s_isKeeper`), owner-only
  `PriceOracleFacet.setKeeper` + `isKeeper` getter, `NOT_KEEPER` error, `KeeperSet` event.
  `sendRequest` now gates on `s_isKeeper`, decoupled from the user whitelist.
  Tests: `OracleSendRequestAuth.t.sol` (incl. new `test_whitelisted_user_cannot_send_request`),
  `CovFinal.t.sol`, `CovMiscTail.t.sol`.
- **#2** — `if (_principal == 0) revert AMOUNT_ZERO();` in `_takeLoan`;
  plus `MAX_ACTIVE_LOANS_PER_POSITION = 50` cap enforced in both `_takeLoan` and
  `_requestBorrow` (`TOO_MANY_ACTIVE_LOANS` error).
  Tests: `testTakeLoanFailsForZeroPrincipal`, `testTakeLoanRevertsAboveActiveLoanCap`.

- **#4** — rewrote `LibLiquidation._liquidateLoan`: the seizure now **caps to
  available collateral** (scaling the repayment down) instead of reverting, so a
  deeply-overdue loan is always liquidatable (kills 4a); and repayment is
  allocated **pro-rata** across principal and interest with a `_principalRepaid > 0`
  guard, so every liquidation retires principal and the interest-only skim is
  impossible (kills 4b). Removed the liquidation-side `REPAYMENT_BELOW_INTEREST`
  floor (the repay-path floor in `LibProtocol` is untouched).
  Tests: `testLiquidateLoan_overduePenaltyExceedsCollateral_stillLiquidatable`,
  `testLiquidateLoan_cannotSkimInterestOnly`; updated `testLiquidateLoanPartial_Success`
  and `CovMiscTail.test_liquidation_loan_belowInterest_reducesPrincipal` to the
  new pro-rata semantics.

- **#5** — replaced the immediate `transferPositionOwnership` with a two-step
  (pull) transfer. `transferPositionOwnership` now only records a proposal
  (`s_pendingPositionTransfer[positionId] = recipient`, emits
  `PositionTransferInitiated`); the recipient must call `acceptPositionTransfer`
  to pull ownership, which re-validates all preconditions and emits
  `PositionIdTransferred`. Added `cancelPositionTransfer` (owner clears a
  proposal) and `getPendingPositionTransfer`. `_transferPositionId` clears any
  pending proposal, so `adminForceTransferPositionOwnership` (unchanged,
  council-only) also invalidates stale proposals. New errors `NO_PENDING_TRANSFER`,
  `NOT_PENDING_RECIPIENT`.
  Tests: `testTransferPositionOwnership` (updated to two-step),
  `testTransferPositionOwnershipRequiresRecipientAccept`,
  `testAcceptPositionTransferFailsForNonRecipient`,
  `testAcceptPositionTransferFailsWhenNonePending`, `testCancelPositionTransfer`,
  updated `testTransferPositionOwnershipEmitsEvent`.

- **#7** — added a per-token aggregate `s_totalCollateralDeposited`, maintained at
  every `s_positionCollateral` write (deposit +, withdraw −, both liquidation
  seizures −). `_removeCollateralToken` now reverts `COLLATERAL_STILL_IN_USE`
  while any position still holds the token, so it can only be delisted once all
  holders have exited — no more zero-valued live collateral.
  Test: `testRemoveCollateralTokenBlockedWhileHeld`.
- **#9** — segregated fixed-loan principal in `TokenVault`. New buckets
  `fixedBorrows` (Σ principal) and `fixedRateProduct` (Σ principal·rate) let
  `_pendingInterest` accrue floating principal at the mutable `interestRate` and
  fixed principal at each loan's snapshotted rate. A governance rate change no
  longer mints phantom interest on fixed loans. `borrow`/`repay` gained
  `borrowFixed(…, rate)` / `repayFixed(…, rate)` variants (the diamond's fixed
  paths — `_takeLoan`, `_requestBorrow`, `_repayLoanFor`, `_liquidateLoan` — call
  them; pooled paths and the direct 2-arg vault API are unchanged). Because the
  two formulas coincide when the rate is constant, no existing accounting test
  changed. `updateBadDebt` scales the fixed buckets to preserve
  `fixedBorrows <= totalBorrows`.
  Test: `test_fixedLoan_accrual_unaffected_by_rate_hike`.

- **#6** — added `if (!s.isWhitelisted[_request.wallet]) revert
  ADDRESS_NOT_WHITELISTED(_request.wallet);` in `_requestBorrow` (after the
  position-match check), mirroring the local borrow path's `_callerWhitelisted`.
  An on-chain blacklist now takes effect even against a pre-signed, unused
  request. Test: `test_requestBorrow_rejects_blacklisted_wallet`.

**Suite:** 410 passing, 0 failing.

**Open:** none.
**No action:** #3 (false positive), #8 (accepted design).
