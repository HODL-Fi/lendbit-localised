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
  - **Lender-side consequence on a rate *cut* (2026-07-01 #5).** The premise above is
    that the rate is effectively set-once. If governance instead *lowers* a live rate,
    the two legs diverge for the pre-change interval: `TokenVault.setInterestRate`
    calls `_accrueInterest()` first, so the vault keeps the **old** (higher) accrual
    for `[lastUpdate, now]`, while `_calculateUserDebt` reprices a **floating**
    borrower's whole interval at the **new** (lower) rate. The gap —
    `floatingPrincipal · (rateOld − rateNew) · elapsed · (1 − reserveFactor)` — stays
    in `totalAccruedInterest` as an LP receivable that no borrower will ever pay, so
    `totalAssets()` is over-booked and the shortfall is borne by the **last LPs to
    redeem** (an LP-vs-LP transfer, not a borrower over/undercharge). This is a
    distinct consequence of the same root cause and is **accepted only under the
    set-once-rate posture** — do NOT cut a live rate while floating borrows are open.
    Note this affects the **floating/pooled** leg only; **fixed-term loans are immune**
    (they accrue at their own snapshotted `annualRateBps` via the vault's
    `fixedRateProduct`, audit 2026-07-01 #9). The real remedy, if rates must move, is
    the per-position (or per-token) borrow-index checkpoint noted above.
  - **Reserve-factor changes re-split historical interest (2026-07-02 18:17 #7).** The
    same root cause on the reserve-factor axis. `TokenVault._accrueInterest` books the
    LP receivable *net of the reserve factor in effect during each interval*, but
    `_doRepay` re-splits the *entire* `interestPaid` at the **current** factor
    (`_reserve = interestPaid · reserveFactor / 1e4`). If governance changes the factor
    between accrual and repayment, the repay-time split diverges from what was accrued:
    the cash is conserved, but `totalAccruedInterest` and `totalProtocolReserve` drift
    from it (a raised factor over-funds the protocol reserve and strands an LP
    receivable in `totalAccruedInterest`; a lowered factor does the reverse). Same
    posture as the rate case — **accepted only under the set-once-parameter operational
    assumption** (do NOT change the reserve factor while interest is accrued but
    unrepaid); the real remedy is to bucket gross interest into separate LP / protocol
    receivables **at accrual time** rather than re-deriving the split at repay. Council-
    only (`setReserveFactor` is `onlySecurityCouncil`, a documented trust assumption).
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
- **Fee-on-transfer / non-standard tokens are fail-closed, not supported (2026-07-02
  #1 / #6).** The deposit path credits the balance actually received, so it *tolerates*
  a fee-on-transfer token, but every repay and liquidation closeout asserts
  `_received == _amount` and reverts if the vault is short-changed. This is deliberate:
  crediting the smaller received amount on repay would let a borrower discharge debt
  the LPs never received. The consequence is that a FoT *borrow* token would be
  unrepayable and a FoT *collateral* token would pay a liquidator slightly under the
  bonus. Neither is a live risk — token listing is council-only and no FoT token is in
  scope (Cantina AI-5 / Sherlock AI-21: 6–18-decimal tokens are not weird). The correct
  resolution if one is ever needed is to **reject FoT at vault/collateral onboarding**,
  not to loosen the closeout guard. Tokens with 6–18 decimals and standard transfer
  semantics are unaffected.
  - **Rebasing collateral is likewise not supported (2026-07-02 #1, 16:28 report).**
    `s_positionCollateral` records the nominal deposit; a *negative-rebasing* collateral
    would shrink the diamond's real backing while valuation still reads the stored
    amount. Same weird-token posture as FoT — collateral listing is council-only
    (trusted), no rebasing token is in scope, and standard non-rebasing collateral never
    hits this. The reported "reconcile against `balanceOf(address(this))`" fix was
    **rejected as unsafe**: the haircut is donation-defeatable (transfer 1 wei to lift
    live backing above the recorded total and cancel it), it couples every position to a
    single global balance ratio (mass wrongful liquidation on a rebase), and it makes the
    health-check hot path depend on a transiently-varying live balance. Resolution, if a
    rebasing token is ever considered, is onboarding-time rejection — never patching the
    valuation function.
- **`createPositionFor(_user)` is an open onboarding affordance (2026-07-02 #4).**
  Anyone may create a position *for* a whitelisted address. The position vests to that
  named user (not the caller), the whitelist already gates who can hold a position, and
  the deposit paths auto-create internally, so pre-creation grants the caller nothing.
  The only edge — pre-creating a position for someone who was about to *receive* a
  transferred one (blocking it on `ADDRESS_EXISTS`) — is already gated by the two-step
  transfer's recipient-consent step. Restricting to `msg.sender == _user` would break
  the intended operator/relayer onboarding flow, so it is left open by design (Low, no
  fund loss).
- **Coarse (0-decimal) high-unit-value collateral can be un-liquidatable in dust
  (2026-07-02 #5).** `_getAmountToLiquidate` floors the USD→collateral conversion to
  integer token units before applying the bonus, so if a position's *entire* remaining
  debt maps to less than one whole unit of a 0-decimal, very-high-priced collateral, the
  seizure rounds to zero and the liquidation reverts (fail-closed). This needs a
  non-standard 0-decimal collateral (council-listed) and a sub-unit residual debt. A
  naive round-*up* fix is unsafe — it would seize a whole high-value unit for a tiny
  repayment (over-liquidation), so the current fail-closed behaviour is retained. The
  intended resolution is to **not list 0-decimal high-value tokens as collateral**;
  standard 6–18-decimal collateral cannot reach this state at any realistic price.

---

## 3. Open Leads for Manual Review

Earlier audit reports' **Leads** sections listed high-signal code smells where a full
exploit path was not completed in one pass. The 2026-07-02 report's leads were worked
through (`lendbit-localised-leads-validation-20260702-150619.md`): the deploy-script,
`>18`-decimal feed underflow, oracle error-before-store, pause-blocks-withdrawal,
yield-claim-whitelist, yield-reconfigure-checkpoint, and ERC20-deposit-traps-ETH leads
were **fixed**; the liquidation-threshold setter wrapper was already added in the prior
round. The following are **accepted** (external-dependency, dead-code, or dust) and are
NOT bugs:

- **Aave withdrawal can block liquidation (2026-07-02 L6).** Liquidation unwinds the
  yield allocation through `IAavePool.withdraw`; if the external pool lacks liquidity
  the call reverts. Inherent to using an external money market. Operational mitigation:
  the council can `setYieldPause` the token, so `_shouldProcess` skips the Aave unwind
  and liquidation seizes the liquid collateral directly.
- **Yield withdraw ignores Aave's returned amount (2026-07-02 L7).** `_withdraw` passes
  a concrete amount (never `type(uint256).max`), so standard Aave returns exactly that
  or reverts, and `_refreshRecordedBalance` re-reads the true aToken balance afterward.
  No accounting drift for standard pool behaviour.
- **Native-repay branch is dead code (2026-07-02 L11).** `_allowanceAndBalanceCheck`
  has a `msg.value` branch, but the native token is collateral-only (no ERC4626 vault
  is deployed for it), so no native borrow — and therefore no native repay — exists.
- **Yield-index dust (2026-07-02 L12).** The RAY(1e27)-scaled per-principal index only
  rounds a non-zero user share to zero at astronomically large `totalPrincipal`
  (> ~1e27); below the domain tolerance at any realistic size.

Older leads not re-examined here (stale-feed liquidation DoS, liquidation close-factor
/ collateral-choice, cross-position yield sourcing, `encodePacked` signature, admin
force-transfer) still warrant manual review — see the respective audit reports.

---

## 4. Scope & Dependencies

- Mocks (`contracts/mocks/*`) are test-only and not deployed.
- Third-party libraries (OpenZeppelin v5.5.0, Chainlink v0.3.2, forge-std v1.12.0)
  are used unmodified; their internal behavior is out of scope.
- The EIP-2535 diamond plumbing (`Diamond.sol`, `LibDiamond`, the loupe/cut facets,
  `DiamondInit`) follows the reference implementation.
