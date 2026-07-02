## §6 Documented Behaviors

BYTE-EXACT verbatim quotes from protocol documentation, design specifications, code comments, and acknowledged issues. These statements establish intentional protocol design that is **not** a vulnerability.

---

### State Machine / Lifecycle

- `README.md:10–12` — "Diamond Architecture — Modular facets (`Protocol`, `VaultManager`, `Liquidation`, `PriceOracle`, `PositionManager`, `YieldStrategy`, etc.) expose isolated functionality while sharing storage through `LibAppStorage`."

- `PROTOCOL_SUMMARY.md:96–99` — "A user should have at most one active position. `s_ownerPosition[user]` and `s_positionOwner[positionId]` should remain reciprocal."

- `Constant.sol:8–12` — "MAX_ACTIVE_LOANS_PER_POSITION = 50; Upper bound on concurrently-active loans per position. Health-factor and liquidation checks walk `s_positionActiveLoanIds` linearly, so an unbounded array lets an attacker bloat the O(N) loop until liquidation exceeds the block gas limit (permanent unliquidatability → bad debt). Capping N keeps that loop's worst-case cost constant."

- `KNOWN_ISSUES.md:74–84` — "Cross-chain borrow health check (audit #5 / 2026-07-01 #1). `_requestBorrow` performs no on-chain collateral/health check on the hub. Cross-chain borrows are **spoke-collateralized**: the collateral lives on the spoke chain, the health check runs there at attestation time, and the result is carried by the signed request (`_verifyBorrowSignature` against `s_requestBorrowSigner`). The hub holds no collateral for these positions, so a hub-side `_getHealthFactor` would read zero collateral and revert every legitimate request — it is intentionally omitted."

- `KNOWN_ISSUES.md:82–84` — "An optional signed `deadline` was added as defence-in-depth. The **minimum tenure** (`ONE_DAY`) IS now enforced on `_requestBorrow`, matching `_takeLoan`."

- `test/audit/AuditReport0701.t.sol:62–68` — "The immutable origination anchor (`s_loanStartTime`) is recorded at request time. Pre-fix it stayed 0, so `_outstandingBalance` fell back to the resettable `_loan.startTimestamp`. Origination anchor is immutable across repayment."

- `test/audit/FixedRateAccrual.t.sol:7–13` — "Finding #9 — the vault used to accrue ALL `totalBorrows` at the mutable `interestRate`, while fixed loans repay at their immutable `annualRateBps`. A governance rate hike then minted phantom interest on fixed principal, inflating the ERC4626 share price so an early LP could extract value the borrower will never pay. The fix accrues fixed principal at its own snapshotted rate, so a rate change leaves the fixed loan's LP accrual untouched."

- `test/audit/AuditReport0701.t.sol:84–90` — "Maturity anchor did NOT move: the loan is still measured against its origination, so it stays past maturity and keeps accruing penalty (pre-fix the anchor reset to the repay time, escaping the penalty and extending tenure)."

- `docs/yield-strategy.md:111–125` — "Deposit Collateral: ProtocolFacet.depositCollateral → LibProtocol._depositCollateral → After transferring tokens, `LibYieldStrategy._rebalancePosition` runs to push the configured percentage into Aave. Withdraw / Liquidation: Prior to sending collateral out, protocol calls `_rebalancePosition` and `_ensureSufficientIdle` to unlock enough idle funds from Aave. Ensures standard withdrawals and liquidations have required liquidity without manual intervention."

---

### Permission / Role Expectations

- `scope.md:80–96` — "Entry-point summary: LP | `deposit`, `withdraw` (VaultManagerFacet); Borrower (whitelisted) | `depositCollateral`, `withdrawCollateral`, `borrow`, `repay`, `takeLoan`, `repayLoan`, `claimYield`, `rebalanceMyPosition`; Keeper (whitelisted) | `sendRequest`, `repayLoanFor`, liquidation entrypoints; Anyone | `liquidateLoan`, `liquidatePosition` (only when the target is liquidatable), view getters; Security council (owner) | vault deploy/upgrade/config, rate setters, pause, bad-debt write-off, collateral-token management, whitelist/blacklist, oracle admin."

- `PROTOCOL_SUMMARY.md:389–392` — "User-facing protocol operations usually require whitelist membership through library checks, especially position-related lending and borrowing actions."

- `KNOWN_ISSUES.md:97–99` — "Privileged roles are trusted. The security council (diamond owner) can set rates, reserve factors, pause vaults, write off bad debt, force-transfer positions, and upgrade vaults. These are assumed to be used correctly; council-only footguns are not treated as vulnerabilities."

- `LibAppStorage.sol:77–82` — "Dedicated keeper allowlist for triggering protocol-funded Chainlink Functions refreshes. Kept separate from `isWhitelisted` (the general borrower/depositor onboarding gate) so ordinary users can never bill the protocol's LINK subscription."

---

### Trust Assumptions

- `scope.md:83–91` — "The **security council** (diamond owner) is trusted for privileged operations (rates, reserve factor, pause, bad-debt write-off, vault upgrade, position force-transfer). The **request-borrow signer** is trusted to attest spoke-chain collateral/health. Price feeds are Chainlink aggregators; staleness/round/positive-answer checks are enforced in `LibPriceOracle._getPriceData`."

- `PROTOCOL_SUMMARY.md:394–409` — "The protocol should maintain these high-level invariants: A user should have at most one active position. Diamond-level vault accounting should stay consistent with `TokenVault` accounting. Vault shares should represent a pro-rata claim on real `TokenVault.totalAssets()`. Borrow capacity and utilization should use consistent total deposit and total borrow bases. Open-ended borrows and fixed-tenure loans should both count toward health factor and liquidation. Repayment and liquidation should reduce the same debt that was actually repaid. Oracle values should normalize both token decimals and feed decimals correctly. Yield principal and accrued yield should remain conserved across position-level and token-level strategy state."

- `KNOWN_ISSUES.md:85–88` — "Fixed APR re-prices open positions on a governance rate change. `s_interestRate` is a single set-once-style rate; changing it re-prices the full elapsed interval of open pooled borrows. Acceptable for a fixed-rate deployment; removing it would require a full per-position borrow-index checkpoint."

- `KNOWN_ISSUES.md:89–94` — "LP yield is capped by utilization. `MAX_UTILIZATION` is a strict `< 90%`, so up to ~10% of deposited capital is always idle (the liquidity buffer LPs exit through). The deployed APR (31.25% → 27.78% after the cap was raised to 90%) is grossed up so LPs realize ~20% on deposit **at the utilization ceiling**; below the cap they earn proportionally less. The full 20%-on-deposit is unreachable by design because 100% utilization is disallowed."

---

### Out-of-Scope

- `scope.md:74–82` — "`contracts/mocks/*` — test-only, never deployed. Third-party dependencies (OpenZeppelin v5.5.0, Chainlink v0.3.2, forge-std) — used unmodified. Spoke-chain contracts and the off-chain attestation signer. `contracts/libraries/LibInterestRateModel.sol` — **removed** (dead code after the borrow path was pinned to the fixed APR; see `KNOWN_ISSUES.md`)."

- `KNOWN_ISSUES.md:113–116` — "Scope & Dependencies: Mocks (`contracts/mocks/*`) are test-only and not deployed. Third-party libraries (OpenZeppelin v5.5.0, Chainlink v0.3.2, forge-std v1.12.0) are used unmodified; their internal behavior is out of scope. The EIP-2535 diamond plumbing (`Diamond.sol`, `LibDiamond`, the loupe/cut facets, `DiamondInit`) follows the reference implementation."

- `KNOWN_ISSUES.md:101–122` — "Open Leads for Manual Review: The audit report's **Leads** section lists high-signal code smells where a full exploit path was not completed in one pass (stale-feed liquidation DoS, liquidation close-factor / collateral-choice, LTV-vs-liquidation-threshold mismatch, yield raw-transfer DoS, cross-position yield sourcing, Aave partial-fill, dual-role price-feed overwrite, `>18`-decimal feed underflow, `encodePacked` signature, admin force-transfer). These are **not** confirmed false positives — they warrant manual review."

