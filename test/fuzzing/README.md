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
  3 pranked actors, 2 ERC20 collaterals + native, and two funded borrow vaults
  with **different decimals** (6d ~$1 and 2d ~$2) to exercise the protocol's
  decimal-normalization math. The 6d borrow token is **also** registered as
  collateral (`dualTok`), so actors can deposit and borrow the same token.
  `borrow`/`repay`/`takeLoan` take a borrow-token
  selector and bound amounts by that vault's raw-unit seed; `repayLoan`/
  `liquidateLoan` fund the actor in the loan's own token (cap scaled to its
  decimals). Per-token invariants compare raw units within a single token, so
  decimal mismatch never confuses them.

### Surface

Handlers (the fuzzed entry points): `depositCollateral`, `withdrawCollateral`,
`borrow`, `repay`, `takeLoan`, `repayLoan`, `liquidateLoan`,
`setCollateralPrice`, `warp`, the LP liquidity path — `vaultDeposit`,
`vaultWithdraw` — plus the yield-strategy path — `rebalanceYield`,
`simulateAaveYield`, `claimYield`, `harvestProtocolYield`.

Invariants (`property_*`, checked after every call):

- `property_collateral_solvency_token1/2` — for each ERC20 collateral, what the
  diamond holds idle **plus** what its Aave strategy holds as aTokens covers the
  collateral it records per position.
- `property_native_collateral_solvency` — same for native collateral.
- `property_collateral_solvency_dual` — the dual token (collateral **and**
  borrowable) is still fully custodied as collateral in the diamond; its borrow
  liquidity lives in a separate vault, so borrowing the same token posted as
  collateral never lets the two balances commingle.
- `property_vault_solvency` — each borrow vault's liquid balance plus
  outstanding borrowed principal always covers net LP principal
  (deposits − withdrawals, tracked in `ghost_vaultNet`). This is the
  fixed-rate LP property: an LP's share value includes accrued interest, but
  they can only *realize* it up to the vault's available liquidity — interest
  sitting on borrowed-out principal isn't withdrawable until borrowers repay.
  `vaultWithdraw` deliberately probes over-withdrawal; the vault must revert
  (`InsufficientBalance`) rather than pay out borrowed-out funds.
- `property_healthy_position_not_liquidatable` — a position with health factor
  ≥ 1e18 is never liquidatable (the two solvency gates can't both fire).
- `property_recorded_debt_covers_vault_principal` — per borrow token, summed
  borrower debt (pooled + P2P, principal + interest) always covers that vault's
  outstanding principal; catches the borrow double-counting class fixed in H-02.
  The P2P leg is bucketed by `loan.token` (not `getTotalActiveDebt`, which mixes
  token units) so it stays sound with more than one borrowable token.
- `property_position_owner_consistency` — every minted position id maps to an
  owner that maps back to the same id.

### Yield strategy

Both ERC20 collaterals are wired to a `MockAavePool` (50% allocation, 10%
protocol share) so the supply / withdraw / accrue / claim / harvest paths are
fuzzed. Collateral routed to Aave leaves the diamond as underlying and returns
1:1 as aTokens, which is why the collateral-solvency invariants count the aToken
balance too. Native collateral has no strategy (the protocol rejects it).

Oracle staleness is disabled in the harness (`setPriceFeedStalenessThreshold`
= `type(uint32).max`) so price-reading paths and invariants don't revert merely
because Medusa advanced `block.timestamp` between calls.

Assertion testing is also on, so any Solidity `assert`/panic-0x01 inside the
protocol during a call sequence fails the run.

## Extending

- Add invariants as `property_*() returns (bool)` functions on the harness.
- To hunt arithmetic over/underflow and divide-by-zero in protocol math, run the
  `medusa-arith.json` variant: `medusa fuzz --config medusa-arith.json`. It turns
  on `failOnArithmeticUnderflow` / `failOnDivideByZero` and runs a deeper soak
  (150k calls, sequence length 250). A panic-0x11 / 0x12 there is a real bug, not
  noise (Solidity custom-error reverts don't trip these). Last soak: 21/21 clean.