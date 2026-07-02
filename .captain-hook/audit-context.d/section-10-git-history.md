## §10 Git History

### Repo Analysis Header

**Analyzed Branch:** `audit-remediation-readiness` (HEAD: 4a2b217)  
**Repository Age:** 322 days (2025-08-13 to 2026-07-01)  
**Total Commits:** 77 | Source-touching: 68 | Test-touching: 61  
**Contributors:** 2 (Benjamin Faruna 70.3%, PhantomOz 29.7%)

---

### Contributor Profile

| Author | Commits | Lines Added | Pct | Role |
|--------|---------|-------------|-----|------|
| Benjamin Faruna | 68 | 4637 | 70.3% | Lead developer; architectural design, testing |
| PhantomOz | 9 | 1957 | 29.7% | Secondary; recent audit remediation (3 commits in past 30d) |

**Development Concentration:** 70% single-author codebase (Benjamin Faruna) through June. Late-stage audit remediation (past 30 days) shifted to PhantomOz.

---

### Security-Focused Commits (Score ≥12)

Top 10 high-scoring commits identified by security signal analysis (explicit security language, access-control tightening, fund-flow changes, accounting logic):

| Rank | SHA | Date | Author | Subject | Score | Domains | Impact |
|------|-----|------|--------|---------|-------|---------|--------|
| 1 | d3f4a48 | 2026-05-03 | Benjamin Faruna | fixed m-6: No Reentrancy Guard on Diamond Facets | 17 | 6 | Adds runtime guards; tightens access control across liquidation, oracle, vault ops |
| 2 | 99c700c | 2026-07-01 | PhantomOz | fix: remediate 2026-07-01 review findings not covered by prior fixes | 16 | 6 | Adds guards; auth handling + accounting fixes (TokenVault, LibLiquidation, LibProtocol) |
| 3 | 33fc8a7 | 2026-02-10 | Benjamin Faruna | add gettersFacet checks for underflow, ps: failing liquidation test | 16 | 5 | Oracle/pricing; accounting logic; net code removal (net security gain) |
| 4 | ee48b1a | 2026-06-24 | PhantomOz | This initiates invariant tests | 15 | 5 | Declares invariant test infrastructure; accounting/state-machine hardening |
| 5 | 5106016 | 2026-07-01 | PhantomOz | fix: resolve audit findings and harden protocol | 13 | 6 | Largest change (1353 lines); touches all facets + core libraries; access-control additions |
| 6 | 9603e1a | 2026-05-05 | Benjamin Faruna | fixed m-10: _ensureSufficientIdle Charges Deficit Only to the Withdrawing Position | 13 | 5 | Accounting; yield withdrawal safety |
| 7 | 501a3a3 | 2026-04-30 | Benjamin Faruna | fixed h-4: Repay Accounting Executes Before Token Transfer (CEI Violation) | 13 | 5 | CEI ordering fix (checks-effects-interactions); non-standard token safety |
| 8 | 53ffdc3 | 2026-03-28 | Benjamin Faruna | fixed liquidation test and updated TokenVault contract | 13 | 6 | Liquidation + oracle + vault integration; accounting |
| 9 | f49f76c | 2026-03-25 | Benjamin Faruna | fixed c-1: Liquidator Can Steal All Borrower Collateral | 13 | 4 | Critical severity; oracle-based liquidation cap |
| 10 | 4a2b217 | 2026-07-01 | PhantomOz | fix: enforce minimum tenure on _requestBorrow | 12 | 5 | Borrow validation; test co-changed (recent) |

**Observation:** 9 of 10 top commits explicitly fix audit findings (h-*, m-*, c-*, l-* labels). Single commit (ee48b1a) declares infrastructure but no deployed invariant tests yet.

---

### Dangerous-Area Evolution

**Fund Flows (65 commits):** 
- Core borrow/repay/liquidation mechanics continuously refined
- Latest 7 commits (June 17 - July 1): double-counting bug (da41636), principal mutation (bf0af1d), ERC4626 vault accounting (ee1350e), tenure validation (4a2b217), general hardening (5106016, 99c700c)
- Pattern: Early commits (Sep–Oct 2025) added deposit/withdraw/borrow logic; mid-stage (Nov 2025 - May 2026) bug fixes and CEI reordering; late-stage (June–July 2026) audit remediation (accounting + precision)

**Access Control (15 commits):**
- Early commits (Sep 2025) added whitelist/role-based controls
- m-6 fix (May 2026) added reentrancy guards across facets
- Latest (July 2026) adds auth guards to TokenVault operations
- Pattern: Access control added piecemeal; final consolidation in 5106016

**Liquidation (61 commits):**
- Highest churn area; 11 commits in latest 30 days alone
- Critical fix (c-1, Mar 2026): liquidator collateral theft → capped liquidation bonus
- H-02 fix (June 2026): double-counting in borrow tallying
- L-7, L-8 (June 2026): minimum tenure + pause state consistency
- Pattern: Early logic (Jan 2025) had collateral calculation gap; multiple rounds of refinement

**Oracle / Price (62 commits):**
- Chainlink integration added Nov 2025 (d735298)
- Stale-price guards added (OracleSendRequestAuth.t.sol, OracleCoverage.t.sol)
- Decimal normalization (scaleUp/scaleDown) added May 2026 (33fc8a7)
- Pattern: Price oracle is youngest major feature; defensive coding added late

**State Machines (61 commits):**
- Loan lifecycle (request → take → repay/liquidate), yield allocation, vault pause states
- Recent focus on invariant tests (ee48b1a, June 24) but no deployed test suites
- Penalty clock edge case tests (PenaltyClock.t.sol) added late

---

### Late-Stage Changes (Past 30 Days)

**Cutoff Date:** 2026-06-01 | **Latest Commit:** 2026-07-01 (00:00 UTC)

| Date | Author | Subject | Files Changed | Test Co-Changed | Lines |
|------|--------|---------|---|---|---|
| 2026-07-01 | PhantomOz | fix: enforce minimum tenure on _requestBorrow | 1 (LibProtocol) | ✅ | 7 |
| 2026-07-01 | PhantomOz | fix: remediate 2026-07-01 review findings not covered by prior fixes | 3 (TokenVault, LibLiquidation, LibProtocol) | ✅ | 66 |
| 2026-07-01 | PhantomOz | fix: resolve audit findings and harden protocol | 30 (core + all facets) | ❌ | 1353 |
| 2026-06-24 | PhantomOz | This initiates invariant tests | 3 (LibDiamond, LibPriceOracle, LibProtocol) | ✅ | 17 |
| 2026-06-17 | Benjamin Faruna | fix H-02: double counting on borrow bug | 1 (LibProtocol) | ✅ | 2 |
| 2026-06-12 | Benjamin Faruna | fixed: Position Transfer Can Overwrite A Recipient's Existing Position Mapping | 1 (LibPositionManager) | ✅ | 1 |
| 2026-06-12 | Benjamin Faruna | Fixed-Term Loan Repayment Calculates Principal Repaid After Principal Is Mutated | 1 (LibProtocol) | ❌ | 4 |
| 2026-06-12 | Benjamin Faruna | Position and Loan Liquidations Leave ERC4626 Vault Borrow Accounting Inflated | 3 (TokenVault, VaultManagerFacet, LibLiquidation) | ✅ | 32 |
| 2026-06-05 | Benjamin Faruna | fixed l-8: _harvestProtocolYield Can Be Called When Strategy Is Paused | 4 (LibYieldStrategy, mocks, Error) | ✅ | 46 |
| 2026-06-05 | Benjamin Faruna | fixed l-7: No Minimum Tenure Validation on _takeLoan | 3 (LibProtocol, Constant, Error) | ❌ | 3 |
| 2026-06-05 | Benjamin Faruna | fixed l-4: _outstandingBalance Calculates Penalty Interest on Original Principal | 3 (LibProtocol, LibYieldStrategy, Constant) | ✅ | 13 |

**Pattern Analysis:**
- 11 commits in 30 days; 8 fix audit findings (h-*, m-*, l-* labels)
- 7 of 11 include test co-changes (63% test-touching rate, below repo avg 79%)
- Largest change (5106016, 1353 lines) lacks test updates; suggests code-only hardening without new test coverage
- Two commits on same day (2026-07-01) from same author indicate batch remediation push

**Risk Signal:** Three commits on 2026-07-01 (audit branch's HEAD) bypass typical review cycle:
- 99c700c (66 lines) + 5106016 (1353 lines) + 4a2b217 (7 lines) = 1426 lines in one day
- 5106016 untested (no test changes) despite touching 30 files
- Suggests emergency audit-readiness push without full regression test coverage

---

### Forked Dependencies

**Chainlink EVM (838 sol files, submodule):**
- Multiple pragma versions (0.8.6 → 0.8.26)
- Used for: Price feed aggregator, AutomationRegistry, FunctionsRouter
- Status: Upstream maintained, no security-critical customizations detected

**OpenZeppelin Contracts (425 sol files, submodule):**
- Multiple pragma versions (0.8.0 → 0.8.27)
- Used for: Ownable, AccessControl, ReentrancyGuard, ERC4626, ERC20
- Status: Upstream maintained, versions lag slightly (0.8.27 available; project uses 0.8.20–0.8.24)

---

### Tech Debt & Code Quality

**Debt Detected:** 0 (no TODO, FIXME, HACK, XXX markers found)

**Quality Signals:**
- Average commit size: 123 lines (reasonable; not megacommits)
- Single-developer phase (70% contributor) risks: design inconsistency, knowledge silos
  - Mitigated by: Late-stage PhantomOz secondary review (3 commits past 30 days)
- No merge-without-approval found; 5 merges over 322 days (low integration frequency)

---

### Synthesis & Threat Model Bridge

**Key Findings:**

1. **Active Audit Remediation (Jun–Jul 2026)**
   - Recent commits explicitly target audit findings (h-*, m-*, l-* categories)
   - Largest change (5106016) untested; suggests urgent hardening over validation
   - Test co-change rate drops to 63% in late period (below 79% repo avg)
   - → **Recommendation:** Regression test suite re-run required before merge

2. **Dangerous-Area Stability**
   - Fund flows, liquidation, oracle: 61–65 commits each (highest churn)
   - Liquidation had critical flaw (c-1 Mar 2026); double-counting bug (h-02 Jun 2026)
   - → **Audit Focus:** Liquidation order-of-operations, collateral valuation precision

3. **Late-Stage Feature Addition (Nov 2025 onward)**
   - Chainlink integration + Aave yield strategy added mid-project
   - Oracle defensive coding (stale-price guards, round ID checks) added May–Jun 2026
   - → **Audit Focus:** Aave integration safety (repay/borrow slippage, rate staleness)

4. **Test Infrastructure Gap**
   - Invariant test framework declared (ee48b1a Jun 24) but no active suites
   - No fuzz testing; 411 deterministic tests only
   - Diamond.sol (core upgrade path) has 0% branch coverage
   - → **Audit Blocker:** Invariant tests must be deployed before mainnet; Diamond upgrade safety requires fork test

5. **Single-Author Dependency**
   - Benjamin Faruna: 70.3% of code; only PhantomOz secondary (recent)
   - Knowledge concentration risk on yield strategy (LibYieldStrategy 171 loc, 13 functions)
   - → **Audit Note:** Yield withdrawal logic (harvest/rebalance) should flag for deep review

**Audit Threat Model Alignment:**
- Git history confirms **reentrancy** (m-6 fix), **CEI violations** (h-4 fix), **oracle stale prices**, **liquidation precision** as principal dangers
- Accounting bugs (double-counting, underflow in penalty accrual) repeatedly patched → architectural fragility signal
- Test gap on Diamond upgrade + oracle staleness + yield deficit paths aligns with identified critical areas
