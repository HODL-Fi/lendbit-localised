```
██████╗██████╗
██╔════╝██╔══██╗
██║     ██║  ██║
██║     ██║  ██║
╚██████╗██████╔╝
╚═════╝╚═════╝

███████╗███████╗ ██████╗██╗   ██╗██████╗ ██╗████████╗██╗   ██╗
██╔════╝██╔════╝██╔════╝██║   ██║██╔══██╗██║╚══██╔══╝╚██╗ ██╔╝
███████╗█████╗  ██║     ██║   ██║██████╔╝██║   ██║    ╚████╔╝
╚════██║██╔══╝  ██║     ██║   ██║██╔══██╗██║   ██║     ╚██╔╝
███████║███████╗╚██████╗╚██████╔╝██║  ██║██║   ██║      ██║
╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝   ╚═╝      ║

Audit Preparation v1.0
```

# Audit Readiness Report — lendbit-localised

**Project:** lendbit-localised | **Framework:** Foundry (Diamond/EIP-2535) | **Scope:** 30 contracts, 3,700 lines

---

## 1. Test Coverage

| Status | Finding | Recommendation |
|--------|---------|----------------|
| FAIL | In-scope branch coverage ~47.6% (118/248) — audit requires ≥90% | Add branch tests until ≥90% before scheduling audit |
| FAIL | 14 build warnings (12 erc20-unchecked-transfer, 2 unsafe-typecast) | Check ERC20 transfer return values; bound truncating typecasts |
| FAIL | DiamondInit.sol — 0% line/function, no test references it | Test `DiamondInit.init()` during diamond deployment |
| FAIL | OwnershipFacet.sol — 0% line/function (deploy-only) | Test `transferOwnership()` / `owner()` execution |
| FAIL | LibDiamond.sol — 44.66% line, 9.38% branch (3/32) | Add diamondCut add/replace/remove branch tests |
| FAIL | LibPriceOracle.sol — 40.91% line, 25% branch (3/12) | Test price-feed staleness and conversion branches |
| FAIL | DiamondLoupeFacet 15%, PriceOracleFacet 12.24%, TokenVault 52% branch | Cover loupe queries, oracle entrypoints, vault edge branches |
| FAIL | LibProtocol 61.97% branch, LibVaultManager 56.25%, LibYieldStrategy 47.73% | Cover remaining branch conditions in core libraries |
| PASS | 100% on DiamondCutFacet, GettersFacet, LiquidationFacet, ProtocolFacet | — |
| PASS | LibPositionManager 97.37% line, 100% branch | — |

_Note: default coverage run hit stack-too-deep at LibProtocol.sol:658 — requires `--ir-minimum`._

## 2. Test Quality

| Status | Finding | Recommendation |
|--------|---------|----------------|
| FAIL | No integration/E2E/fork test files across 26 contracts | Add `test/*Integration*.sol` exercising cross-facet flows |
| PASS | Assertion density 2.22/test (451/203), above 2.0 threshold | — |
| PASS | 46 edge-case checks; 43.8% negative/revert tests; 15 fuzz/invariant occurrences | — |

## 3. NatSpec Documentation

| Status | Finding | Recommendation |
|--------|---------|----------------|
| FAIL | 68 of 87 public/external functions undocumented (no @notice/@param/@return) | Add NatSpec to all public/external functions |
| FAIL | 22 of 26 contracts/libraries lack a @title tag | Add `/// @title` above each contract and library |
| FAIL | 5+ named returns lack @return tags (LibDiamond, OwnershipFacet, LibVaultManager…) | Add `/// @return` matching each named return |
| PASS | All 62 @param tags match parameter names — no copy-paste mismatches | — |

## 4. Code Hygiene

| Status | Finding | Recommendation |
|--------|---------|----------------|
| FAIL | All 30 files use floating caret pragmas | Pin to a single fixed version (e.g. `pragma solidity 0.8.30`) |
| FAIL | Four distinct pragma versions (^0.8.0, ^0.8.3, ^0.8.19, ^0.8.30) | Standardize every contract on one version |
| PASS | No TODOs, console imports, test imports, or commented-out code; all SPDX present | — |
| PASS | Consistent error handling (218 custom errors vs 2 require) | — |

## 5. Dependencies

| Status | Finding | Recommendation |
|--------|---------|----------------|
| PASS | All 3 submodules initialized (chainlink v0.3.2, forge-std v1.12.0, OZ v5.5.0) | — |
| PASS | No modified/patched dependencies; lock files all present | — |

## 6. Best Practices

| Status | Finding | Recommendation |
|--------|---------|----------------|
| FAIL | Raw ERC20 transfer/transferFrom/approve without SafeERC20 (LibVaultManager:38,41; LibYieldStrategy:118,143,222; LibPriceOracle:194) | Add `using SafeERC20 for IERC20`; use safeTransfer/safeTransferFrom/forceApprove |
| FAIL | 6 risk/rate-parameter setters emit no events (LibVaultManager `_setReserveFactor`/`_setBaseRate`/`_setSlopeRate`/`_setOptimalUtilization`/`_setLiquidationBonus`; TokenVault `setInterestRate`) | Emit an update event after each state write |
| PASS | No CEI violations; nonReentrant on external state-changing functions | — |
| PASS | Zero-address checks, oracle staleness validation, guarded admin functions, pause mechanism, checked ETH/low-level calls | — |

## 7. Deployment Readiness

| Status | Finding | Recommendation |
|--------|---------|----------------|
| FAIL | No contract verification config (etherscan/blockscout/sourcify) | Add `[etherscan]` config and `--verify` to deploy commands |
| FAIL | Working tree dirty — uncommitted changes to LibProtocol.sol | Commit or stash before audit handoff |
| PASS | Clean build; 199/199 tests pass; deploy scripts and README setup/deploy docs present | — |

## 8. Project Documentation

| Status | Finding | Recommendation |
|--------|---------|----------------|
| FAIL | No known-issues file/section | Create `KNOWN_ISSUES.md` listing limitations and accepted risks |
| FAIL | No scope definition (scope.md/json) | Create `scope.md` listing in-scope contracts, chains, entry points |
| PASS | Architecture, trust model, and invariants documented in README + PROTOCOL_SUMMARY.md | — |

---

## Score Summary

| Phase | Score |
|-------|-------|
| 1. Test Coverage | 3/100 |
| 2. Test Quality | 95/100 |
| 3. NatSpec Documentation | 5/100 |
| 4. Code Hygiene | 80/100 |
| 5. Dependencies | 100/100 |
| 6. Best Practices | 72/100 |
| 7. Deployment Readiness | 75/100 |
| 8. Project Documentation | 75/100 |
| **Overall** | **63/100 — Needs Work (coverage below 90%)** |

## Quick Wins

| # | Action | Location |
|---|--------|----------|
| 1 | Raise in-scope branch coverage to ≥90% (LibDiamond, LibPriceOracle, DiamondInit, OwnershipFacet first) | test/ |
| 2 | Fix 14 compiler warnings (ERC20 return checks, unsafe typecasts) | contracts/ |
| 3 | Wrap raw ERC20 calls with SafeERC20 | LibVaultManager, LibYieldStrategy, LibPriceOracle |
| 4 | Pin and unify Solidity pragma across all 30 files | contracts/ |
| 5 | Add NatSpec (@notice/@param/@return) + @title to facets and libraries | contracts/ |

---

## Static Analysis Summary

**Slither** (filtered, in-scope): 3 `incorrect-equality` (strict `==` in `TokenVault` deposit/withdraw/_accrueInterest), 1 `uninitialized-local` (`PriceOracleFacet.sendRequest`), 4 `unused-return`; remainder naming-convention/informational. Full output: `slither-fresh.json`.

**Aderyn**: 6 High — arbitrary `from` in `transferFrom` (LibVaultManager), unprotected initializer (PriceOracleFacet/LibPriceOracle/DiamondInit), Yul `return` in Diamond, unprotected native-ETH send (ProtocolFacet), unchecked return value (LibVaultManager/LibYieldStrategy), locked Ether (Diamond); plus 10 Low. Full output: `aderyn-report.md`.

The deep 12-agent security review (13 findings + 14 leads) is in `lendbit-localised-pashov-ai-audit-report-20260626-173900.md`.
