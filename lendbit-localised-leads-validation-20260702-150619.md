# Leads Validation — lendbit-localised (report 2026-07-02 15:06)

_Working through the **Leads** section of
`lendbit-localised-pashov-ai-audit-report-20260702-150619.md` (unscored,
manual-review trails). Six are genuine and fixed; six are accepted / dead-code /
already-resolved and documented._

Verdicts: `FIXED`, `RESOLVED (prior)`, `ACCEPTED (documented)`.

---

## Leads table

| # | Lead | Location | Verdict | Sev | Action |
|---|------|----------|---------|-----|--------|
| L1 | Deployment script incomplete (missing facets + deployer not whitelisted) | `Deployment.run` | ✅ FIXED | Deploy-correctness | Added YieldStrategy + Getters cuts; whitelist deployer before `createPositionFor` |
| L2 | Feed decimals can underflow valuation | `LibPriceOracle._calculateTokenUSDEquivalent` | ✅ FIXED | Low | Handle `feedDecimals > 18` by scaling down |
| L3 | Functions error callback reverts before storing error | `LibPriceOracle._fulfillRequest` | ✅ FIXED | Low | Decode only on non-empty response; always persist `err` |
| L4 | Liquidation-threshold setter has no exposed wrapper | `LibProtocol._setCollateralLiquidationThreshold` | ✅ RESOLVED (prior) | — | `ProtocolFacet.setCollateralLiquidationThreshold` already added |
| L5 | Pausing token support blocks LP withdrawals | `LibVaultManager._pauseTokenSupport/_withdraw` | ✅ FIXED | Low/Med | Withdrawals no longer gated on `s_supportedToken` |
| L6 | Aave withdrawal dependency can block liquidation | `LibYieldStrategy._rebalanceForWithdrawal` | 🟡 ACCEPTED | Low | External dep; pause-yield operational mitigation |
| L7 | Yield withdrawal ignores returned amount | `LibYieldStrategy._withdraw` | 🟡 ACCEPTED | Info | Benign for concrete-amount Aave withdraw; balance re-read after |
| L8 | Yield claim bypasses whitelist freeze | `YieldStrategyFacet.claimYield` | ✅ FIXED | Low | Whitelist gate on `claimYield` |
| L9 | Yield reconfiguration skips checkpointing | `LibYieldStrategy._configureYieldToken` | ✅ FIXED | Low | `_accrueYield` before rebaselining |
| L10 | ERC20 collateral deposits can trap ETH | `LibProtocol._depositCollateral` | ✅ FIXED | Low/Info | Reject `msg.value != 0` on the ERC20 path |
| L11 | Native borrow repayment boundary is nonpayable | `LibProtocol._allowanceAndBalanceCheck` | 🟡 ACCEPTED | Info | Dead branch — native is collateral-only, never borrowable |
| L12 | Yield index dust marked processed without distribution | `LibYieldStrategy._accrueYield` | 🟡 ACCEPTED | Info | RAY(1e27)-scaled index; dust unreachable at realistic principal |

---

## Fixed — per-lead notes

### L1 — Deploy script incomplete — FIXED
`scripts/Deploy.s.sol` cut only 7 of 9 facets (omitting `YieldStrategyFacet` and
`GettersFacet` — all yield + getter selectors would be unreachable) and called
`createPositionFor(msg.sender)` without whitelisting the deployer first, which reverts
`ADDRESS_NOT_WHITELISTED` and aborts the whole broadcast. **Fix:** import/deploy/cut
both missing facets (cut array 7→9) and `whitelistAddress(msg.sender)` before
`createPositionFor`. (Deploy-path correctness, not a live-attacker vector; the test
harness already wires all 9 facets.)

### L2 — Feed decimals underflow — FIXED
`scaledPrice = _price * (10 ** (PRECISION_SCALE - _feedDecimals))` underflows the
unsigned exponent when a feed reports `> 18` decimals, reverting every valuation for
that token (borrow/health/liquidation DoS). **Fix:** branch on `_feedDecimals <= 18`
and scale down (`_price / 10 ** (feedDecimals - 18)`) otherwise. Feed selection is
privileged (Low), but the guard removes the footgun entirely. PoC:
`test_feed_decimals_above_18_does_not_dos_valuation`.

### L3 — Error callback reverts before storing error — FIXED
On a DON error the response is empty and `abi.decode("", (uint256))` reverts *before*
`res.err = _err`, so the error is never recorded and the router callback reverts.
**Fix:** decode `priceData` only when `_response.length > 0`; always persist `_err`.
PoC: `test_oracle_error_fulfillment_does_not_revert` (pre-fix reverts, post-fix
records the error). Note the Functions `priceData` does not feed lending valuation
(that uses the Chainlink `AggregatorV3Interface` feeds), so impact is observability —
fixed regardless.

### L5 — Pause blocks LP withdrawals — FIXED
`_withdraw` required `s_supportedToken[_token]`, but `_pauseTokenSupport` clears that
flag, so pausing/delisting a token trapped every LP's deposit until resume. A
withdrawal only returns the LP's own principal and reduces protocol exposure, so it
must stay open during a pause. **Fix:** drop the `s_supportedToken` gate from
`_withdraw` (the zero-vault check, moved ahead of the position lookup, still rejects
never-vaulted tokens with `TOKEN_NOT_SUPPORTED`). New deposits/borrows remain gated.
PoC: `test_lp_can_withdraw_while_token_support_paused`.

### L8 — Yield claim bypasses whitelist — FIXED
`claimYield` checked only position ownership, so a user blacklisted after accruing
yield could still pull it — defeating the freeze that every other value-extracting
path (`_borrow`, `_withdraw`, collateral deposit, and the deposit-side gate added for
the prior blacklist finding) honours. **Fix:** `_addressIsWhitelisted(msg.sender)` in
`claimYield`. (`rebalanceMyPosition` is intentionally left ungated — it moves collateral
to/from Aave without extracting value.) PoC: `test_blacklisted_user_cannot_claim_yield`.

### L9 — Reconfiguration erases pending yield — FIXED
`_configureYieldToken` overwrote `lastRecordedBalance` with the live aToken balance
without accruing first, so re-tuning an already-enabled token silently discarded the
yield accrued since the last touch (the `currentBalance − lastRecordedBalance` delta
never reached the index). **Fix:** `_accrueYield(s, _token)` before the config is
reassigned (no-ops for a fresh token via `_shouldProcess`). PoC:
`test_reconfigure_distributes_pending_yield`.

### L10 — ERC20 deposit traps ETH — FIXED
`depositCollateral` is `payable` for the native path; on the ERC20 path `msg.value`
was ignored, so ETH sent alongside an ERC20 deposit was trapped. **Fix:**
`_validateAmount` now reverts `AMOUNT_MISMATCH(msg.value, 0)` when a non-native deposit
carries value. Self-inflicted (Low/Info) but cheaply prevented. PoC:
`test_erc20_collateral_deposit_rejects_eth`.

---

## Accepted / resolved — per-lead notes

### L4 — Threshold setter wrapper — RESOLVED (prior round)
`ProtocolFacet.setCollateralLiquidationThreshold` (council-only) and
`GettersFacet.getCollateralLiquidationThreshold` were added during the 2026-07-01
23:30 remediation. The parameter is fully tunable on-chain. No further action.

### L6 — Aave withdrawal can block liquidation — ACCEPTED (Low)
Liquidation unwinds yield via `_rebalanceForWithdrawal → IAavePool.withdraw`; if the
Aave pool lacks liquidity the call reverts and the liquidation cannot proceed. This is
inherent to using an external money market, and the council retains an operational
mitigation — pausing the token's yield strategy (`setYieldPause`) makes
`_shouldProcess` skip the Aave unwind, so liquidation seizes the liquid collateral
directly. External-dependency risk, no code change.

### L7 — Yield withdraw ignores return value — ACCEPTED (Info)
`_withdraw` ignores Aave's returned `withdrawn`, but it passes a concrete `_amount`
(never `type(uint256).max`), so standard Aave returns exactly that amount or reverts;
`_refreshRecordedBalance` then re-reads the true aToken balance, so the index stays
correct. Benign for standard pool behaviour; no fund-flow drift.

### L11 — Native borrow repay nonpayable — ACCEPTED (Info, dead branch)
`_allowanceAndBalanceCheck` has a native (`msg.value`) branch, but the native token is
registered as **collateral only** — borrowable tokens require an ERC4626 vault over an
ERC20, and none is deployed for the native sentinel. So no native borrow exists and the
native repay branch is unreachable defensive code. No change.

### L12 — Yield index dust — ACCEPTED (Info)
`accYieldPerPrincipalRay += (_userShare * RAY) / totalPrincipal` rounds to zero only
when `_userShare < totalPrincipal / 1e27`. With RAY = 1e27 and any realistic
`totalPrincipal` (≤ ~1e24), a non-zero `_userShare` always advances the index. Dust
loss requires an astronomically large principal; below the domain tolerance (DI-4).
No change.

---

## Remediation status (this branch)

**Fixed (with PoCs in `test/audit/AuditLeads0702.t.sol`):** L2, L3, L5, L8, L9, L10.
**Fixed (deploy correctness):** L1 (`scripts/Deploy.s.sol`).
**Resolved prior:** L4.
**Accepted / documented:** L6, L7, L11, L12 (KNOWN_ISSUES §3).

**Suite:** 432 passing, 0 failing.
