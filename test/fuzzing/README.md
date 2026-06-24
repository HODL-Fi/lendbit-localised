# Medusa fuzzing

Stateful (invariant) fuzzing for the Lendbit diamond using
[medusa](https://github.com/crytic/medusa).

## One-time tooling

```bash
go install github.com/crytic/medusa@latest        # the fuzzer  -> ~/go/bin/medusa
brew install pipx && pipx install crytic-compile  # compilation driver
# optional, improves value mining:
pipx install slither-analyzer
```

Make sure `~/go/bin` and `~/.local/bin` are on your `PATH`.

## Run

```bash
medusa fuzz                       # full campaign (testLimit in medusa.json)
medusa fuzz --test-limit 50000    # bounded run
```

The harness uses `vm.ffi` (in `LendbitFuzz`'s constructor, via
`scripts/genSelectors.js`) to wire up the diamond — exactly like the Foundry
tests — so `enableFFI` is set in `medusa.json`. `node` must be on `PATH`.

A coverage report is written to `medusa-corpus/coverage/coverage_report.html`.

## Layout

- `medusa.json` (repo root) — fuzzer + compilation config.
- `test/fuzzing/LendbitFuzz.sol` — the harness: deploys the diamond + 9 facets,
  3 pranked actors, 2 ERC20 collaterals + native, and one funded borrow vault.

### Surface

Handlers (the fuzzed entry points): `depositCollateral`, `withdrawCollateral`,
`borrow`, `repay`, `takeLoan`, `repayLoan`, `liquidateLoan`,
`setCollateralPrice`, `warp`.

Invariants (`property_*`, checked after every call):

- `property_collateral_solvency_token1/2` — the diamond custodies at least the
  ERC20 collateral it records per position.
- `property_native_collateral_solvency` — same for native collateral.
- `property_position_owner_consistency` — every minted position id maps to an
  owner that maps back to the same id.

Assertion testing is also on, so any Solidity `assert`/panic-0x01 inside the
protocol during a call sequence fails the run.

## Extending

- Add invariants as `property_*() returns (bool)` functions on the harness.
- To also catch arithmetic over/underflow and divide-by-zero in protocol math,
  flip `failOnArithmeticUnderflow` / `failOnDivideByZero` to `true` under
  `assertionTesting.panicCodeConfig` in `medusa.json` (expect more noise).
- Yield/Aave strategy is left unconfigured so collateral stays in the diamond
  and the solvency invariants are exact. Wire `MockAavePool` + yield configs in
  the constructor to fuzz that path.