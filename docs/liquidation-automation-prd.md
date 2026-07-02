# PRD: Liquidation Automation Service

## Overview

Build an off-chain backend service that detects liquidatable Lendbit positions, simulates liquidation transactions, and optionally executes profitable liquidations.

This service is liquidation-only. User health-factor notifications are handled by the separate Health Factor Notification Service.

## Goals

- Detect positions eligible for liquidation.
- Identify profitable liquidation opportunities.
- Simulate liquidation transactions before execution.
- Execute liquidations only when automation is enabled.
- Track liquidation attempts, outcomes, and profitability.

## Non-Goals

- Send health factor warnings to users.
- Store user emails or notification preferences.
- Modify liquidation rules in the smart contracts.
- Guarantee liquidation profitability.

## Contract Interfaces

### Liquidation

```solidity
function isLiquidatable(uint256 positionId) external view returns (bool);
function liquidatePosition(uint256 positionId, uint256 amount, address token, address collateralToken) external;
function liquidateLoan(uint256 loanId, uint256 amount, address collateralToken) external;
```

### Getters

```solidity
function getPositionBorrowedValue(uint256 positionId) external view returns (uint256);
function getBorrowDetails(uint256 positionId, address token) external view returns (uint256);
function getTotalActiveDebt(uint256 positionId) external view returns (uint256);
function getUserActiveLoanIds(uint256 positionId) external view returns (uint256[] memory);
function getLoanDetails(uint256 loanId)
    external
    view
    returns (
        uint256 positionId,
        address token,
        uint256 principal,
        uint256 repaid,
        uint256 tenureSeconds,
        uint256 startTimestamp,
        uint256 debt,
        uint16 annualRateBps,
        uint16 penaltyRateBps,
        uint8 status
    );
function getOutstandingDebtForLoan(uint256 loanId) external view returns (uint256);
function getPositionCollateral(uint256 positionId, address token) external view returns (uint256);
function getAllCollateralTokens() external view returns (address[] memory);
```

### Position Manager

```solidity
function getUserForPositionId(uint256 positionId) external view returns (address);
function getNextPositionId() external view returns (uint256);
```

### ERC20

```solidity
function balanceOf(address account) external view returns (uint256);
function allowance(address owner, address spender) external view returns (uint256);
function approve(address spender, uint256 amount) external returns (bool);
```

## Events To Index

```solidity
event PositionIdCreated(uint256 indexed positionId, address indexed user);
event PositionIdTransferred(uint256 indexed positionId, address indexed oldAddress, address indexed newAddress);
event BorrowComplete(uint256 indexed positionId, address indexed token, uint256 amount);
event Repay(uint256 indexed positionId, address indexed token, uint256 amount);
event LoanTaken(uint256 indexed positionId, uint256 indexed loanId, address indexed token, uint256 principal, uint256 tenureSeconds, uint16 annualRateBps);
event LoanRepayment(uint256 indexed positionId, uint256 indexed loanId, address indexed token, uint256 amount);
event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, address indexed token, uint256 amountToLiquidate);
event LoanLiquidated(uint256 indexed positionId, uint256 indexed loanId, address indexed token, address liquidator, uint256 amountLiquidated);
```

## User Story

As a liquidator operator, I want the bot to identify and execute profitable liquidations so the protocol remains solvent and the liquidator earns liquidation bonuses.

## Functional Requirements

### Position Discovery

The service must maintain a list of positions to scan.

Implementation:

- Index `PositionIdCreated`.
- Update ownership on `PositionIdTransferred`.
- Reconcile with `getNextPositionId()` and `getUserForPositionId(positionId)`.

Data model:

```text
positions
- position_id
- owner_address
- status
- updated_at
```

### Liquidatability Scanner

For each known position:

```solidity
isLiquidatable(positionId)
getPositionBorrowedValue(positionId)
getTotalActiveDebt(positionId)
getUserActiveLoanIds(positionId)
```

Only continue if `isLiquidatable(positionId) == true`.

Data model:

```text
liquidatable_positions
- id
- position_id
- owner_address
- open_borrow_debt_value
- active_loan_debt_value
- detected_block
- detected_at
```

### Open-Ended Borrow Liquidation Discovery

For liquidatable positions with open-ended borrow debt:

- Determine borrowed tokens to inspect.
- For each borrowed token, call `getBorrowDetails(positionId, token)`.
- Ignore tokens with zero debt.
- For each collateral token from `getAllCollateralTokens()`, call `getPositionCollateral(positionId, collateralToken)`.
- Ignore collateral tokens with zero balance.
- Build candidate calls:

```solidity
liquidatePosition(positionId, repayAmount, borrowedToken, collateralToken)
```

Candidate selection rules:

- `repayAmount` must be greater than zero.
- `repayAmount` must be affordable by the liquidator wallet.
- Candidate must pass call simulation.
- Expected profit must exceed configured minimum.

### Fixed-Loan Liquidation Discovery

For each active loan:

```solidity
getLoanDetails(loanId)
getOutstandingDebtForLoan(loanId)
```

For each collateral token held by the position, build candidate calls:

```solidity
liquidateLoan(loanId, repayAmount, collateralToken)
```

Candidate selection rules:

- `repayAmount` must be greater than zero.
- `repayAmount` must be affordable by the liquidator wallet.
- Candidate must pass call simulation.
- Expected profit must exceed configured minimum.

### Profitability Checks

The service must estimate:

- Repayment token cost.
- Expected collateral received.
- Collateral token USD value.
- Gas cost.
- Net profit.

Skip liquidation if:

```text
expected_collateral_value_usd - repay_value_usd - gas_cost_usd < MIN_LIQUIDATION_PROFIT_USD
```

### Transaction Simulation

Before sending any transaction:

- Check ERC20 balance.
- Check ERC20 allowance.
- Simulate approval if needed.
- Simulate liquidation call with `eth_call` or equivalent SDK call simulation.
- Estimate gas.
- Reject candidate if simulation reverts.

### Execution

Execution must only happen when:

```text
ENABLE_LIQUIDATIONS=true
```

Open-ended liquidation:

```solidity
IERC20(repayToken).approve(diamond, repayAmount);
liquidation.liquidatePosition(positionId, repayAmount, repayToken, collateralToken);
```

Fixed-loan liquidation:

```solidity
IERC20(repayToken).approve(diamond, repayAmount);
liquidation.liquidateLoan(loanId, repayAmount, collateralToken);
```

### Attempt Recording

Data model:

```text
liquidation_opportunities
- id
- position_id
- loan_id
- liquidation_type
- repay_token
- repay_amount
- collateral_token
- estimated_collateral_received
- estimated_profit_usd
- estimated_gas_cost_usd
- simulation_status
- decision
- reason
- created_at
```

```text
liquidation_attempts
- id
- opportunity_id
- position_id
- loan_id
- liquidation_type
- tx_hash
- status
- revert_reason
- gas_used
- repay_token
- repay_amount
- collateral_token
- collateral_received
- created_at
- confirmed_at
```

## Backend Services

### Indexer Worker

Responsibilities:

- Backfill protocol events.
- Subscribe to new protocol events.
- Maintain active positions and active loan references.

### Liquidatability Worker

Responsibilities:

- Scan positions on a schedule.
- Detect liquidatable positions.
- Queue candidates for opportunity analysis.

### Opportunity Worker

Responsibilities:

- Build liquidation candidates.
- Estimate profitability.
- Simulate transactions.
- Store opportunities and decisions.

### Execution Worker

Responsibilities:

- Execute approved profitable opportunities.
- Track receipts.
- Store final outcomes.
- Alert operators on repeated failures.

## Configuration

```text
CHAIN_ID
RPC_URL
DIAMOND_ADDRESS
DEPLOYMENT_BLOCK
PRIVATE_KEY_LIQUIDATOR
ENABLE_LIQUIDATIONS=false
MIN_LIQUIDATION_PROFIT_USD=5
MAX_GAS_COST_USD=20
SCAN_INTERVAL_SECONDS=60
CONFIRMATION_BLOCKS=2
LIQUIDATION_TOKEN_ALLOWLIST
COLLATERAL_TOKEN_ALLOWLIST
MAX_REPAY_AMOUNT_USD
```

## API Endpoints

### `GET /liquidations/opportunities`

Returns detected liquidation opportunities.

### `GET /liquidations/attempts`

Returns liquidation attempts and outcomes.

### `POST /liquidations/:opportunityId/simulate`

Manually re-simulates an opportunity.

### `POST /liquidations/:opportunityId/execute`

Manually executes an opportunity if it still passes simulation and profitability checks.

## Safety Requirements

- Default `ENABLE_LIQUIDATIONS=false`.
- Always simulate before execution.
- Use a dedicated liquidator wallet.
- Keep limited funds in the liquidator wallet.
- Use repayment token and collateral token allowlists.
- Use database locks to avoid duplicate liquidation attempts.
- Re-check `isLiquidatable(positionId)` immediately before execution.
- Recompute profitability immediately before execution.
- Never execute if expected profit is below threshold.
- Record revert reasons.

## Observability

Metrics:

```text
positions_scanned_total
positions_liquidatable_total
liquidation_opportunities_total
liquidation_simulations_total
liquidation_simulation_failures_total
liquidation_attempts_total
liquidation_success_total
liquidation_failed_total
average_liquidation_profit_usd
rpc_errors_total
```

Logs must include:

- position ID
- loan ID if applicable
- liquidation type
- repay token
- repay amount
- collateral token
- estimated profit
- transaction hash
- revert reason

## Edge Cases

- Position becomes healthy between scan and execution.
- Another liquidator wins the transaction first.
- Collateral token balance is insufficient for selected repay amount.
- Liquidator has insufficient repayment token balance.
- ERC20 approval transaction succeeds but liquidation later reverts.
- Gas price spikes after profitability estimate.
- RPC simulation succeeds but mined transaction reverts because state changed.

## MVP Scope

Phase 1:

- Detect liquidatable positions.
- Build liquidation candidates.
- Simulate liquidation calls.
- Store opportunities.
- Manual execution only.

Phase 2:

- Add profitability estimation.
- Add token inventory checks.
- Add operator dashboard.

Phase 3:

- Enable automated execution.
- Add advanced routing and token inventory management.
- Add multi-RPC failover.

## Acceptance Criteria

- Service detects liquidatable positions.
- Service builds open-ended and fixed-loan liquidation candidates.
- Service simulates all candidates before execution.
- Service records profitable and rejected opportunities.
- Service does not execute transactions unless `ENABLE_LIQUIDATIONS=true`.
- Service records transaction outcomes.
- Service avoids duplicate liquidation submissions for the same opportunity.
