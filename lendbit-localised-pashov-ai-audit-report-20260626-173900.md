# 🔐 Security Review — lendbit-localised

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | default (all in-scope `.sol`)                          |
| **Files reviewed**               | `Diamond.sol` · `TokenVault.sol` · `DiamondCutFacet.sol`<br>`DiamondLoupeFacet.sol` · `GettersFacet.sol` · `LiquidationFacet.sol`<br>`OwnershipFacet.sol` · `PositionManagerFacet.sol` · `PriceOracleFacet.sol`<br>`ProtocolFacet.sol` · `VaultManagerFacet.sol` · `YieldStrategyFacet.sol`<br>`LibProtocol.sol` · `LibVaultManager.sol` · `LibLiquidation.sol`<br>`LibYieldStrategy.sol` · `LibInterestRateModel.sol` · `LibPriceOracle.sol`<br>`LibDiamond.sol` · `LibPositionManager.sol` · `LibUtils.sol` · _(+ models, init)_ |
| **Confidence threshold (1-100)** | 75                                                     |

---

## Findings

### Remediation status (updated 2026-06-30)

| # | Finding | Score | Status |
| :-- | :------ | :---: | :----- |
| 1 | Loan/pooled repay & liquidation under-count the borrow tally | 88 | ✅ **Resolved** — diamond (`s_positionPrincipal`) **and** vault legs |
| 2 | Unauthenticated `sendRequest` drains LINK subscription | 82 | ✅ Resolved — keeper-whitelist-gated + forced stored subscription id |
| 3 | ERC4626 `mint`/`redeem` lack `onlyDiamond` | 80 | ✅ **Resolved** — both overridden with `onlyDiamond` |
| 4 | Depositor accrual at a frozen, decoupled rate → share insolvency / JIT | 80 | ✅ **Resolved** — accrual synced to protocol rate; time-weighted, no JIT |
| 5 | `_requestBorrow` no health check / no signature deadline | 80 | ✅ Resolved — health check by design (cross-chain attestation); optional `deadline` added |
| 6 | Dust repayment resets clock → escapes penalty / extends tenure | 80 | ✅ **Resolved** — penalty pinned to immutable maturity + min-repayment guard |
| 7 | Diamond-mediated `withdraw` reverts on ERC4626 allowance | 80 | ✅ **Resolved** — diamond exempt from the share-allowance check |
| 8 | `totalDeposits` decremented by interest-inclusive withdrawals → DoS | 78 | ✅ **Resolved** — decrement by principal portion (proportional to shares) |
| 9 | Bad-debt write-off & pause reachable from no facet | 78 | ✅ **Resolved** — facet wiring (`setInterestRate` already wired via #4) |
| 10 | `_upgradeVault` strands deposits (no migration) | 75 | ✅ Resolved — reverts `VAULT_NOT_EMPTY` unless the vault is empty |
| 11 | `_calculateUserDebt` applies spot rate to the whole interval | 75 | ✅ Resolved — pinned pooled debt to the fixed APR (no utilization input) |
| 12 | Partial repayment folds interest into principal (compounding) | 75 | ✅ **Resolved** — interest-first, principal-only reduction |
| 13 | Vault deposits use raw ERC20 calls / no balance-diff | 75 | ✅ **Resolved** — SafeERC20 + balance-diff credit |
| — | **uint16 `annualRateBps + penaltyRateBps` overflow bricks overdue loans** *(found via fuzzing this round)* | — | ✅ **Resolved** — `uint256` cast in `_outstandingBalance` |

**Also added (feature, not a finding):** a **protocol interest reserve** — interest accrues to LPs net of the per-token `reserveFactor`, the protocol's slice realizes into a claimable reserve (`TokenVault.totalProtocolReserve`) pulled via `VaultManagerFacet.harvestVaultReserve`.

Resolved items carry dated remediation notes inline below; every fix has a dedicated validating PoC. Final verification: **222 Foundry tests** + a **27-invariant Medusa fuzzer** + a **150k-call Medusa arithmetic soak** (panic-on-underflow/divide-by-zero), all passing.


[88] **1. Loan liquidation under-counts `config.totalBorrows`, corrupting utilization for the whole pool**

`LibLiquidation._liquidateLoan` / `LibProtocol._repayStateChanges` · Confidence: 88

**Description**
Origination adds only `_loan.principal` to `config.totalBorrows` (`LibProtocol.sol:107,165`), and `_repayLoanFor` was patched to subtract a principal-capped amount (`:243`), but `_liquidateLoan` (`LibLiquidation.sol:72`) and `_repayStateChanges` (`LibProtocol.sol:319`) still subtract the full repaid `_amount` (principal + interest + penalty), so each liquidation deflates the borrow tally below true outstanding principal — understating utilization, under-pricing interest for every borrower, and inflating the utilization borrow cap (`MAX_UTILIZATION`).

**Fix**

```diff
- LibVaultManager._updateVaultRepays(s, _loan.token, _amount);
+ uint256 _principalRepaid = _amount > _loan.principal ? _loan.principal : _amount;
+ LibVaultManager._updateVaultRepays(s, _loan.token, _principalRepaid);
```
(apply the same principal-cap at `LibProtocol.sol:319`; capture `_loan.principal` before mutation)

> **Remediation note (2026-06-27) — validated, fixed (diamond-side); vault-side leg deferred**
>
> Confirmed true positive and reproduced. The pooled liquidation leg drifts the tally below other borrowers' principal: two `200e6` loans → `config.totalBorrows` falls to `800e6` (`< 1000e6` of still-owed principal) after liquidating one; the pooled `_repay` leg is identical (`890e6 < 1000e6`). PoCs: `test/audit/BorrowTallyUndercount.t.sol`, `test/audit/PooledBorrowTally.t.sol`.
>
> **The one-line cap above is incomplete for the pooled `borrow`/`repay` path.** `_borrow` raises `config.totalBorrows` by `capitalizedInterest`, **not** principal (`LibProtocol.sol:282`), so capping only the repay side leaves the tally asymmetric. Applied fix:
> - Append `s_positionPrincipal[positionId][token]` to `StorageLayout` (end of struct — upgrade-safe).
> - `_borrow`: raise the tally by principal (`_amount`) and record `s_positionPrincipal += _amount`.
> - `_repayStateChanges` / `_repayLoanFor` / `_liquidateLoan`: decrement by `min(amount, s_positionPrincipal)` and reduce the tracker.
>
> Result: `config.totalBorrows == outstanding principal` across both loan and pooled paths — fixing utilization, the `MAX_UTILIZATION` borrow cap, and (where used) variable interest pricing. _(snapshot at the time of this note: 201 unit tests + a 160k-call invariant fuzz; final state is 222 tests, see the status block.)_
>
> **Vault-side leg — NOW RESOLVED (was deferred, blocked by #4 and #12).** Originally the vault-side leg could not be fixed surgically: `TokenVault.repay`'s `else` branch deducted the full repaid amount from its own `totalBorrows`, and a naive `repay(principal, interest)` split was unsafe because the vault accrued on its own frozen rate (#4) and `_loan.principal` folded interest into principal (#12), leaving residual accrued interest that inflated `totalAssets` (reproduced: 650e6 vs the correct 632e6). Once #4 (accrual synced to the protocol rate) and #12 (interest-first, no folding) were resolved, the vault-side fix became safe and is now in place: `repay(principalRepaid, interestPaid)` reduces `totalBorrows` by **principal only** and splits the interest into the smoothly-accrued LP receivable + the protocol reserve. `vault.totalBorrow()` now tracks true outstanding principal — confirmed by `test/audit/PooledBorrowTally.t.sol` (`vault.totalBorrow() == true principal`). Both ledgers (`config.totalBorrows` and `vault.totalBorrow()`) are consistent.
>
> **Fixed-rate deployment context.** Under the intended fixed-rate configuration the utilization→rate curve is not the borrower-pricing mechanism, so #1's interest-pricing impact narrows to **borrow-cap correctness** — `_validateVaultUtlization` still gates `takeLoan`, and the fix above preserves it. #4's share-insolvency surface narrows but does not vanish: even at a single fixed rate, #12's principal capitalization makes loans accrue on an inflated base while the vault accrues on the corrected principal, so the two ledgers still drift until #12 is addressed.

---

[82] **2. Unauthenticated `sendRequest` drains the protocol's Chainlink LINK subscription**

`PriceOracleFacet.sendRequest` · Confidence: 82

**Description**
Every other Functions mutator is `enforceIsContractOwner`-gated, but `sendRequest` has no guard and forwards a caller-supplied `subscriptionId` straight to `i_router.sendRequest`; since the diamond is the registered consumer, any address can loop calls billed to the protocol's publicly-readable subscription, draining its LINK and DoSing the price-refresh path at ~0 attacker cost.

**Remediation note (2026-06-30): resolved — keeper-gated + stored subscription id.** Price refreshes are keeper-triggered, so `sendRequest` is now gated on the existing keeper whitelist (`isWhitelisted`, the same guard `repayLoanFor`/liquidations use), not locked to the owner. The caller-supplied `subscriptionId` is overwritten with the protocol's stored `s.s_subscriptionId` before the request is forwarded, so it can never be redirected to bill another subscription. A non-whitelisted caller reverts `ADDRESS_NOT_WHITELISTED`; the owner whitelists keepers via `whitelistAddress`. Tests (`OracleSendRequestAuth.t.sol`, with a mock Functions router that bills per request): pre-fix the attacker's call did not revert and the caller-supplied id was billed; post-fix the attacker reverts and a whitelisted keeper's request is billed to the protocol's own subscription.

```diff
  function sendRequest(uint64 subscriptionId, string[] calldata args) external returns (bytes32 requestId) {
      LibAppStorage.StorageLayout storage s = LibAppStorage.appStorage();
+     // keeper-triggered refresh: only whitelisted keepers may bill the
+     // protocol's LINK subscription; caller-supplied id is ignored.
+     if (!s.isWhitelisted[msg.sender]) revert ADDRESS_NOT_WHITELISTED(msg.sender);
+     subscriptionId = s.s_subscriptionId;
      FunctionsRequest.Request memory req;
```

**Status: resolved.**
---

[80] **3. ERC4626 `mint`/`redeem` lack the `onlyDiamond` guard, bypassing protocol accounting**

`TokenVault.mint` / `TokenVault.redeem` · Confidence: 80

**Description**
`deposit` and `withdraw` are overridden with `onlyDiamond`, but the inherited OZ ERC4626 `mint`/`redeem` are not overridden and stay public, so a shareholder calls `redeem(shares, self, self)` directly (`msg.sender == owner`, no allowance needed), pulling assets while `LibVaultManager._withdraw` — the only place `config.totalDeposits` is decremented — is bypassed, permanently desyncing the deposit accounting that drives utilization and interest.

**Fix**

```diff
+ function mint(uint256 shares, address receiver) public override onlyDiamond returns (uint256) {
+     return super.mint(shares, receiver);
+ }
+ function redeem(uint256 shares, address receiver, address owner) public override onlyDiamond returns (uint256) {
+     return super.redeem(shares, receiver, owner);
+ }
```

> **Remediation note (2026-06-30) — validated + resolved (fix as suggested).** Confirmed the bypass: after depositing 1,000 through the diamond (`totalDeposits = 1,000`), a shareholder could call `vault.redeem(shares, self, self)` directly (OZ `redeem` invokes the *internal* `_withdraw`, sidestepping the overridden `onlyDiamond` `withdraw`), pulling the assets out while `config.totalDeposits` stayed at 1,000 — stale. That over-counts the same denominator #8 under-counts: the borrow cap (`MAX_UTILIZATION × totalDeposits`) and the utilization/interest model are inflated against liquidity that has left the vault → over-borrowing, LPs unable to withdraw. Applied the suggested fix: `mint` and `redeem` are now overridden with `onlyDiamond`, so every vault entry/exit flows through the diamond's accounting (and the reserve/pause/position checks). Verified by `test/audit/DirectRedeemBypass.t.sol` (a direct `redeem` now reverts `OnlyDiamond`; deposit accounting stays correct).

---

[80] **4. Vault accrues depositor interest at a frozen rate decoupled from borrower payments → share insolvency**

`TokenVault._accrueInterest` / `totalAssets` · Confidence: 80

**Description**
The vault's `interestRate` is fixed at construction to `_config.baseRate` and `setInterestRate` is never wired to a facet, so `totalAccruedInterest` grows on a flat rate unrelated to the utilization-based rate borrowers actually pay; `totalAssets` therefore drifts from collectible funds, letting a JIT depositor front-run the repayment NAV jump and leaving the last withdrawers unable to redeem full share value.

**Fix**

```diff
- new TokenVault(..., _config.baseRate)            // depositor accrual frozen at baseRate
+ // drive _accrueInterest from interest actually collected from borrowers,
+ // or expose setInterestRate via a facet and push the protocol rate on every change
```

> **Remediation note (2026-06-27) — resolved (second fix option taken).** The vault now accrues at the **protocol rate**, not the frozen `baseRate`: `LibProtocol._setInterestRate` pushes the new rate into every vault (`TokenVault.setInterestRate`) on each governance change, and `_deployVault`/`_upgradeVault` seed the vault with `s_interestRate`. Depositor accrual therefore tracks what borrowers actually pay (time-weighted), so a late LP only earns interest accrued **after** they deposit and there is no repayment NAV jump to front-run — the JIT vector is closed. Verified by `test/audit/InterestModel.t.sol::test_late_lp_does_not_capture_past_interest` (a deposit-before-repay earns nothing). `totalAssets` no longer drifts from collectible funds. The redesign also adds a **protocol reserve**: interest accrues to LPs NET of the token's `reserveFactor`, and the protocol's slice is realized into a claimable reserve (`TokenVault.totalProtocolReserve`) pulled via `VaultManagerFacet.harvestVaultReserve` — mirroring `harvestProtocolYield`. See `test_reserve_cut_and_harvest`.

---

[80] **5. `_requestBorrow` disburses loans with no on-chain health check and no signature deadline**

`LibProtocol._requestBorrow` · Confidence: 80

**Description**
Unlike `_takeLoan`/`_borrow`, which both revert below `MIN_HEALTH_FACTOR`, `_requestBorrow` performs zero on-chain collateral/health validation and the signed `BorrowRequest` has no `deadline`.

**Remediation note (2026-06-30): health check is by design.** `_requestBorrow` is the **hub-side** disbursement entry for cross-chain borrows. The collateral lives on the **spoke chain**, and the health check runs there at attestation time; the hub holds no view of spoke-chain collateral. The signed request (`_verifyBorrowSignature`, `LibProtocol.sol:142`, against `s_requestBorrowSigner`) **is** that attestation — a redundant on-chain health factor on the hub would be wrong, as it has nothing to measure against. The "no on-chain health check" half of this finding is therefore not a hub-side bug.

The only separable residual is the **missing signature deadline**. The `nonce` makes each signature single-use (`s_requestBorrowNonceUsed`, `LibProtocol.sol:144-147`), but a signed request never expired and could be submitted at any later time. Whether this matters depends on the spoke-side design: if the spoke locks collateral at attestation and holds it until the hub confirms, the lock already bounds the risk; if the spoke does not lock at attestation, an expiry bounds the staleness window.

**Remediation note (2026-06-30): optional `deadline` added.** `BorrowRequest` now carries a `deadline` field (`models/Protocol.sol`), folded into the signed hash in `_verifyBorrowSignature` so the signer fixes the expiry. `_requestBorrow` enforces it as an **opt-in** check: `deadline == 0` means no expiry (unchanged behaviour), and a non-zero `deadline` rejects with `REQUEST_BORROW_EXPIRED` once `block.timestamp` passes it. Tests: `testRequestBorrowFailsAfterDeadline` (stale request reverts) and `testRequestBorrowSucceedsWithinDeadline` (in-window request fulfils); the existing `deadline: 0` flows are unaffected.

```diff
  struct BorrowRequest {
      ...
      address wallet;
+     uint256 deadline; // 0 = no expiry (optional)
  }

  // _requestBorrow, after the contract-mismatch guard:
+ if (_request.deadline != 0 && block.timestamp > _request.deadline) {
+     revert REQUEST_BORROW_EXPIRED(_request.deadline, block.timestamp);
+ }

  // _verifyBorrowSignature hash, appended:
+ _request.deadline
```

**Status: resolved** — health check by design (spoke-chain attestation); optional `deadline` implemented.
---

[80] **6. Borrower escapes overdue penalty and extends tenure indefinitely with a dust repayment**

`LibProtocol._repayLoanFor` · Confidence: 80

**Description**
Every partial repayment sets `_loan.startTimestamp = block.timestamp` while `_outstandingBalance` only charges penalty when `block.timestamp > startTimestamp + tenureSeconds`, so repaying 1 wei resets both the penalty clock and the maturity window — a borrower keeps an overdue loan permanently "current" at base rate.

**Fix**

```diff
- _loan.startTimestamp = block.timestamp;
+ // preserve the original origination timestamp so interest/penalty accrue
+ // against fixed maturity; enforce a minimum repayment amount
```

> **Remediation note (2026-06-27) — resolved (both halves of the suggested fix).** Two changes:
> 1. **Fixed maturity.** `_outstandingBalance` now measures the penalty window against the **immutable** origination time (`s_loanStartTime[loanId]`, written once at `takeLoan`), not the resettable `_loan.startTimestamp`. Base interest still accrues from the anchor but is **capped at that fixed maturity**, so resetting the anchor on repay can no longer move the maturity or the penalty clock. (The signature gained an `_originationTime` param; the storage overload supplies it.)
> 2. **Minimum repayment.** `_repayLoanFor` now requires the repayment to cover the accrued interest+penalty (`if (_amount < _interestDue) revert REPAYMENT_BELOW_INTEREST`), so a dust payment can neither reset the interest anchor nor escape accrued interest. Combined with the interest-first allocation from #12, every repayment fully settles accrued interest before the anchor is reset — no interest is ever lost.
>
> Result: an overdue loan stays overdue and keeps accruing penalty across partial repayments; dust repayments revert. Verified by `test/audit/PenaltyClock.t.sol` (`test_dust_repayment_reverts`, `test_partial_repay_does_not_reset_penalty_clock`).

---

[80] **7. Diamond-mediated `withdraw` always reverts on the ERC4626 allowance check**

`TokenVault.withdraw` (via `LibVaultManager._withdraw`) · Confidence: 80

**Description**
`_withdraw` calls `_tokenVault.withdraw(_amount, _to, user)` with the diamond as the EVM caller, so inside the vault `msg.sender (diamond) != owner (user)` and `_spendAllowance(owner, diamond, shares)` (`TokenVault.sol:188`) reverts — the deposit flow never grants a user→diamond share allowance, and the vault's `onlyDiamond` guard blocks the user's own `msg.sender==owner` path. The project's own test only passes because it manually `approve`s the diamond first (`test/VaultManager.t.sol:76`). Funds are recoverable via a manual approval, so this breaks core functionality rather than locking funds.

**Fix**

```diff
- if (msg.sender != owner) {
+ if (msg.sender != owner && msg.sender != diamond) {
      _spendAllowance(owner, msg.sender, shares);
- }
+ }
```

> **Remediation note (2026-06-27) — validated + resolved (fix as suggested).** Confirmed: a depositor calling `vaultManagerF.withdraw` reverts with `ERC20InsufficientAllowance(diamond, 0, shares)` because the vault sees `msg.sender == diamond != owner` and the deposit flow never grants a user→diamond share approval. Applied the suggested diff — the diamond is exempt from the allowance check. This is safe because `withdraw` is `onlyDiamond` and the diamond's `_withdraw` pins `owner` to the calling depositor (`_tokenVault.withdraw(_amount, _to, msg.sender)`), so it can only ever burn the caller's own shares — no third party can move another user's shares through the diamond. Verified by `test/audit/DiamondWithdraw.t.sol` (`test_depositor_can_withdraw_without_share_approval`): a depositor now withdraws with no separate share approval.

---

[78] **8. `totalDeposits` decremented by interest-inclusive withdrawals → utilization clamp DoSes borrowing**

`LibVaultManager._withdraw` · Confidence: 78

**Description**
`_deposit` increments `config.totalDeposits` by raw principal, but `_withdraw` decrements it by the full asset amount paid out (principal + accrued yield), so the counter monotonically under-counts and clamps to 0 — forcing `calculateUtilization` to 100%, which maxes the interest model and makes `_validateVaultUtlization` reject new borrows even while the vault holds ample liquidity.

> **Remediation note (2026-06-27) — resolved.** `_withdraw` now decrements `config.totalDeposits` by the **principal portion** of the withdrawal — proportional to the shares burned — instead of the interest-inclusive asset amount:
> ```solidity
> uint256 _supplyBefore = _tokenVault.totalSupply();
> uint256 _depositsBefore = _config.totalDeposits;
> uint256 _shares = _tokenVault.withdraw(_amount, _to, msg.sender);
> uint256 _principalOut = _supplyBefore == 0 ? 0 : (_depositsBefore * _shares) / _supplyBefore;
> // totalDeposits -= _principalOut   (was: -= _amount)
> ```
> Because `_principalOut ≤ totalDeposits` always (`shares ≤ totalSupply`), the counter never drifts below the real supplied principal and only reaches 0 when the last shares are withdrawn — so utilization stays correct and borrows are no longer DoS'd. The decrement nets to zero across a full deposit→withdraw cycle. Verified by `test/audit/DepositCounterDrift.t.sol` (after an interest-inclusive withdrawal, `totalDeposits` tracks the remaining principal and a fresh borrow still validates). *Note:* the `calculateUtilization` denominator double-count is a separate item (Leads); this fix addresses the drift/DoS.

---

[78] **9. Bad-debt write-off and emergency pause are implemented but reachable from no facet**

`TokenVault.updateBadDebt` / `setPaused` / `setInterestRate` · Confidence: 78

**Description**
All three are `onlyDiamond` but no facet exposes them, so when an underwater liquidation leaves residual unrecoverable principal, `totalAssets` keeps counting it (share price stays inflated) with no path to socialize the loss — the first depositor to withdraw is made whole at later depositors' expense, and the emergency stop is unusable.

> **Remediation note (2026-06-30) — resolved.** All three are now reachable:
> - **`setInterestRate`** was already wired during the #4 fix — `LibProtocol._setInterestRate` pushes the protocol rate into every vault.
> - **`updateBadDebt`** and **`setPaused`** are now exposed via `onlySecurityCouncil` facet functions `VaultManagerFacet.writeOffBadDebt(token, amount)` and `setVaultPaused(token, paused)` (through new `LibVaultManager._writeOffBadDebt` / `_setVaultPaused`).
>
> Bad-debt write-off lowers the vault's `totalBorrows` → `totalAssets`/share price, socializing the loss across all current LPs instead of leaving it for late withdrawers. The pause halts deposits in an emergency. Verified by `test/audit/BadDebtAndPause.t.sol` (write-off drops share price; a paused vault reverts deposits with `VaultPaused` and resumes on unpause).

---

[75] **10. `_upgradeVault` strands all existing deposits — no asset/share/borrow migration**

`LibVaultManager._upgradeVault` · Confidence: 75

**Description**
The upgrade deploys a fresh `TokenVault`, overwrites `s.i_tokenVault[_token]`, and zeroes the config without migrating the old vault's assets, user shares, or `totalBorrows`; the old vault is `onlyDiamond` and now unreferenced, so 100% of pre-upgrade deposits become permanently unreachable and post-upgrade repayments route to the wrong vault. Security-council–gated (operational footgun, not a malicious-admin path), but a concrete one-call fund-strand with no recovery.

**Remediation note (2026-06-30): resolved — empty-vault guard.** A faithful migration is infeasible: ERC4626 LP shares live in the old vault contract and the protocol keeps no holder registry, so they cannot be re-issued in a new vault on-chain. Rather than pretend to migrate, `_upgradeVault` now **refuses to swap the contract while it holds value** — it reverts `VAULT_NOT_EMPTY` when the old vault has outstanding shares (`totalSupply() != 0`) or outstanding borrows (`config.totalBorrows != 0`). The vault contract can therefore only be replaced pre-launch or after a full drain, eliminating the strand. Routine parameter changes (`reserveFactor`, base/slope rate, optimal utilization, liquidation bonus) already have dedicated in-place setters and are unaffected.

```diff
  TokenVault _oldVault = s.i_tokenVault[_token];
  if (address(_oldVault) == address(0)) revert TOKEN_NOT_SUPPORTED(_token);
+ // swapping the contract migrates no assets/shares/borrows (#10) -> only allow it while empty
+ uint256 _shares = _oldVault.totalSupply();
+ uint256 _borrows = s.s_tokenVaultConfig[_token].totalBorrows;
+ if (_shares != 0 || _borrows != 0) revert VAULT_NOT_EMPTY(_shares, _borrows);
  TokenVault _tokenVault = new TokenVault(...);
```

Validation (`UpgradeVaultStrand.t.sol`): pre-fix an upgrade after a deposit returned a new empty vault and orphaned the deposit; post-fix it reverts `VAULT_NOT_EMPTY` (both with outstanding shares and with outstanding borrows), while an upgrade of an empty vault still succeeds.

If live vault-logic upgrades are ever required, the correct architecture is to make `TokenVault` a proxy (UUPS/transparent) so the implementation can change without moving funds or shares — a larger change deferred as a roadmap item.

**Status: resolved** (empty-vault guard; in-place logic upgrades would need a proxy refactor).

---

[75] **11. `_calculateUserDebt` applies the spot utilization rate to a borrower's entire elapsed interval**

`LibProtocol._calculateUserDebt` · Confidence: 75

**Description**
With no per-period interest checkpoint, debt is `spotRate(now) × (now − lastUpdate)`, so any utilization change (a whale borrow, or the `totalDeposits→0` clamp from #8) retroactively reprices a borrower's full history — inflating an otherwise-healthy position past the liquidation threshold and enabling a wrongful liquidation that seizes collateral plus bonus.

**Remediation note (2026-06-30): resolved — pinned to the fixed APR.** The protocol runs at a fixed, governance-set APR (`s.s_interestRate`). The pooled `_calculateUserDebt` was the one place still pricing off the utilization curve (`LibInterestRateModel.calculateInterestRate(config, utilization)`), which (a) let a same-block utilization spike retroactively reprice a borrower's interval and (b) decoupled borrower debt from the vault's (fixed-rate) LP accrual. The fix prices interest at `s.s_interestRate` over actual elapsed time, so a borrower's debt is independent of who else borrows, and what borrowers owe now equals what LPs + protocol receive.

```diff
- VaultConfiguration memory _config = s.s_tokenVaultConfig[_token];
  uint256 _from = s.s_positionBorrowedLastUpdate[_positionId][_token];
  uint256 _timeElapsed = block.timestamp - _from;
- uint256 utilization = LibInterestRateModel.calculateUtilization(_config.totalBorrows, _config.totalDeposits);
- uint256 interestRate = LibInterestRateModel.calculateInterestRate(_config, utilization);
+ uint256 interestRate = s.s_interestRate; // fixed APR — no manipulable utilization input
  uint256 factor = ((interestRate * _timeElapsed) * 1e18) / (10000 * 365 days);
  debt = _amount + _tokenBorrows + ((_tokenBorrows * factor) / 1e18);
```

Validation (`PooledDebtUtilizationReprice.t.sol`): pre-fix a whale spiking utilization ~0→70% lifted an existing borrower's 30-day debt `101.64 → 102.91` token (+1.2%) with **zero** time elapsed; post-fix the borrower's debt is unchanged by the spike. Two liquidation tests that were written around the old decoupling were re-tuned to the fixed rate.

**Fixed-rate economics (verified — `FixedRateLpSplit.t.sol`).** With the borrower and vault rates coupled, the set APR splits per borrowed dollar into a `reserveFactor` protocol slice and a `(1 − reserveFactor)` LP slice (the time-weighted vault accrual). Two properties the deployment relies on:
- **LP yield tracks current utilization** — interest accrues only on `totalBorrows`, so idle capital earns nothing and a late LP cannot capture interest on funds that were never lent. At 50% utilization the LP realizes half the at-cap yield.
- **The 90% utilization cap.** `MAX_UTILIZATION` is a strict `< 90%`, so the pool can never reach 100% utilization — ~10% of deposited capital always sits idle (the liquidity buffer LPs exit through). To let LPs still realize 20% on deposit at the cap, the deployment **grosses the APR up by 1/0.9**: `setInterestRate(2778, …)` (27.78% APR) with the 20% `reserveFactor` gives **~20% LP / ~5% protocol on deposited capital at the 90% ceiling** (22.22% / 5.56% per borrowed dollar). Below the cap LP yield scales down with utilization. `scripts/Deploy.s.sol` sets the 27.78% APR; the test asserts ~20% LP at 89% util and ~11.1% at 50% util. (The cap is a liquidity-vs-yield dial: a higher cap lets the APR drop for the same LP return but shrinks the exit buffer.)

**Status: resolved** (fixed-rate model; a governance APR change still reprices open positions' full interval — acceptable for a set-once rate, removable only with a full borrow-index checkpoint).

---

[75] **12. Partial repayment capitalizes accrued interest into principal (silent compounding)**

`LibProtocol._repayLoanFor` · Confidence: 75

**Description**
`_loan.principal = _loanDebt - _amount` folds outstanding interest and penalty into principal, and the next `_outstandingBalance` accrues simple interest on that inflated base — turning simple interest into compounding and overcharging borrowers who repay in installments (distinct fix site from #6: track principal and accrued interest separately).

> **Remediation note (2026-06-27) — resolved.** `_repayLoanFor` and `LibLiquidation._liquidateLoan` now allocate **interest-first** and reduce `_loan.principal` by the **principal portion only**, so interest is never folded into principal and simple interest stays simple:
> ```solidity
> uint256 _interestDue   = _loanDebt - _oldPrincipal;
> uint256 _principalRepaid = _amount > _interestDue ? _amount - _interestDue : 0;
> _loan.principal = _oldPrincipal - _principalRepaid;   // was: _loanDebt - _amount
> ```
> The same `_principalRepaid` now drives the pool borrow tally (#1) and the vault's `repay(principal, interest)` split, so the loan's remaining principal, `config.totalBorrows`, and `vault.totalBorrow()` stay mutually consistent. Verified by `test/audit/BorrowTallyUndercount.t.sol` and `TokenVault.t.sol::testVaultTotalBorrowsWithDebtsAndRepay`. The earlier sub-interest-carry residual (a repayment smaller than accrued interest resetting the clock) is now also closed by **finding #6**'s fix — partial repayments must cover accrued interest, and the penalty/maturity clock is pinned to the immutable origination time.

---

[75] **13. Vault deposits use raw ERC20 calls and no balance-diff accounting**

`LibVaultManager._deposit` · Confidence: 75

**Description**
`_deposit` uses raw `IERC20.transferFrom`/`approve` (the sibling collateral path uses `safeTransferFrom`) and credits `totalDeposits` from the nominal amount, so no-bool-return tokens like USDT make every deposit revert on the bool decode, and fee-on-transfer tokens overstate `totalDeposits` versus assets actually received.

> **Remediation note (2026-06-30) — resolved.** `_deposit` now mirrors the collateral path — `SafeERC20` (`safeTransferFrom` + `forceApprove`) and a balance-diff credit:
> ```solidity
> uint256 _before = _tokenI.balanceOf(address(this));
> _tokenI.safeTransferFrom(_from, address(this), _amount);
> uint256 _received = _tokenI.balanceOf(address(this)) - _before;
> _config.totalDeposits += _received;          // was: += _amount (nominal)
> _tokenI.forceApprove(address(_tokenVault), _received);
> shares = _tokenVault.deposit(_received, _from);
> ```
> No-bool-return tokens (USDT) now deposit without reverting, and fee-on-transfer tokens credit the amount actually received, not the nominal. Verified by `test/audit/WeirdTokenDeposit.t.sol` (a USDT-style no-return mock deposits successfully; a 1%-fee token credits `990` for a `1,000` deposit). *Note:* full fee-on-transfer correctness on the share-minting side would also require balance-diff inside `TokenVault.deposit` (a second transfer hop); supporting FoT tokens is a separate deployment decision.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [88] | Liquidation under-counts `totalBorrows`, corrupting pool utilization |
| 2 | [82] | Unauthenticated `sendRequest` drains LINK subscription |
| 3 | [80] | ERC4626 `mint`/`redeem` lack `onlyDiamond`, bypass accounting |
| 4 | [80] | Vault depositor rate decoupled from borrower payments → insolvency |
| 5 | [80] | `_requestBorrow` no on-chain health check (by design — spoke-chain attestation) / optional signature deadline |
| 6 | [80] | Dust repayment resets penalty clock & tenure |
| 7 | [80] | Diamond-mediated `withdraw` reverts on ERC4626 allowance check |
| 8 | [78] | `totalDeposits` drift clamps utilization → borrow DoS |
| 9 | [78] | `updateBadDebt`/`setPaused` reachable from no facet |
| 10 | [75] | `_upgradeVault` strands all existing deposits |
| 11 | [75] | `_calculateUserDebt` retroactive spot-rate repricing |
| 12 | [75] | Partial repayment capitalizes interest into principal |
| 13 | [75] | Vault deposits use raw ERC20 + no balance-diff |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one pass. Not false positives — high-signal leads for manual review. Not scored._

- **Stale/reverting feed bricks liquidation** — `LibPriceOracle._getPriceData` — Code smells: reverts on `STALE_PRICE_FEED`/`INVALID_PRICE_FEED`; valuation iterates every held token — one degraded feed blocks liquidation of the whole position, accruing bad debt during oracle downtime.
- **Interest-rate model divide-by-zero** — `LibInterestRateModel.calculateInterestRate` — Code smells: `_setOptimalUtilization` enforces ≥5000 but `_deployVault`/`_upgradeVault` write `optimalUtilization` unvalidated; a 0 (or 10000) value bricks all borrow/repay/liquidation math for that token. _(Neutralized by #11: `calculateInterestRate` is no longer called anywhere — borrower debt is pinned to the fixed APR — so this is now unreachable dead code. Remove the function or keep it only if a variable-rate mode is reintroduced.)_
- **Utilization denominator double-counts liquidity** — `LibInterestRateModel.calculateUtilization` — Code smells: `totalBorrows*1e4/(totalDeposits + totalBorrows)` where `totalDeposits` is already total liquidity → understates utilization, biasing the dynamic rate low. _(Neutralized by #11: `calculateUtilization` is no longer called by any pricing path; the borrow cap uses `totalDeposits × MAX_UTILIZATION` directly. Now dead code.)_
- **Whitelist not re-checked on vault supply/withdraw** — `LibVaultManager._deposit`/`_withdraw` — Code smells: whitelist checked only at position creation; a blacklisted user keeps lending/withdrawing while borrow/collateral paths block them (sanction evasion, no direct fund loss).
- **Yield claim/harvest raw transfer DoS** — `LibYieldStrategy._claimYield`/`_harvestProtocolYield` — Code smells: raw `IERC20.transfer` with bool check; no-return tokens make all yield claims revert (distinct fix site from #13).
- **Cross-position yield liquidity sourcing** — `LibYieldStrategy._rebalanceForWithdrawal` — Code smells: deficit computed from the diamond's aggregate balance but charged against one position's `principal`; can DoS a funded withdrawal and drift `totalPrincipal`.
- **Aave partial-fill ignored** — `LibYieldStrategy._withdraw` — Code smells: discards Aave `withdraw`'s returned actual amount while callers subtract the full requested amount from principal.
- **Liquidation: no close factor + caller-chosen collateral** — `LibLiquidation._liquidatePosition` — Code smells: no debt cap (sibling `_liquidateLoan` has one) and no post-liquidation health recheck; liquidator cherry-picks which collateral token to seize the bonus on.
- **Liquidation threshold vs LTV mismatch** — `LibLiquidation._isLiquidatable` — Code smells: borrow guard uses LTV-weighted collateral (HF≥1e18), liquidation uses raw collateral ×90%; high-LTV tokens can be liquidatable immediately after a permitted borrow.
- **`encodePacked` with leading dynamic string** — `LibProtocol._verifyBorrowSignature` — Code smells: `keccak256(abi.encodePacked(action /*string*/, fixed fields...))` admits hash-collision signature reuse; trailing `contractAddress==this` constraint makes a useful collision implausible but the pattern should use `abi.encode`.
- **`abi.decode` of empty oracle response** — `LibPriceOracle._fulfillRequest` — Code smells: unconditional `abi.decode(_response,(uint256))`; error fulfillments carry empty `_response` and revert; impact low only because `priceData` isn't consumed by valuation today.
- **Price-feed slot overwrite for dual-role tokens** — `LibProtocol._addCollateralToken` — Code smells: `s_tokenPriceFeed[_token]` shared between borrowable-feed and collateral-feed setters with last-writer-wins; `_removeCollateralToken` leaves the feed in place.
- **Admin force-transfer position seizure** — `PositionManagerFacet.adminForceTransferPositionOwnership` — Code smells: council moves any position (collateral+yield+debt) to a controlled whitelisted address then withdraws collateral; centralization unless README designates the council fully trusted for user funds.
- **`>18`-decimal feed underflow** — `LibPriceOracle._calculateTokenUSDEquivalent` — Code smells: `10 ** (18 - _feedDecimals)` underflows for a >18-decimal feed, bricking all flows for the token (low likelihood for standard Chainlink feeds).

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
