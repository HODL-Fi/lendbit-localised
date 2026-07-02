# PRD: Health Factor Notification Service

## Overview

Build an off-chain backend service that monitors hodl user positions and notifies users when their health factor approaches liquidation risk.

This service is notification-only. It must not execute liquidations.

## Goals

- Use the application database as the source of user wallets and contact information.
- Resolve each user's current on-chain position ID from their wallet address.
- Compute each position's current health factor.
- Monitor open-ended debt and fixed-term loan debt.
- Notify users when risk thresholds are crossed.
- Store notification history and delivery status.

## Non-Goals

- Execute liquidation transactions.
- Estimate liquidation profitability.
- Store notification contact data on-chain.
- Modify protocol smart contracts.
- Monitor wallets that are not present in the application database.
- Run a full protocol event indexer for the MVP.

## Contract Interfaces

### Position Manager

```solidity
function getPositionIdForUser(address user) external view returns (uint256);
function getUserForPositionId(uint256 positionId) external view returns (address);
```

### Getters

```solidity
function getHealthFactor(uint256 positionId, uint256 currentBorrowValue) external view returns (uint256);
function getPositionBorrowedValue(uint256 positionId) external view returns (uint256);
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
```

### Liquidation Read

```solidity
function isLiquidatable(uint256 positionId) external view returns (bool);
```

## Data Source

The application database is the primary source of wallets to monitor. All current user wallets and contact information already exist in the app database.

The notification service does not need to discover positions from chain events for the MVP. It should read users from the app database, call `getPositionIdForUser(wallet)`, and skip wallets that return `0`.

## User Story

As a borrower, I want to receive warnings when my position health factor gets low so I can add collateral or repay debt before liquidation.

## Functional Requirements

### Wallet and Position Resolution

The service must scan users from the app database and resolve their on-chain positions.

Implementation:

- Query active app users with wallet addresses.
- Normalize wallet addresses to lowercase.
- For each wallet, call `getPositionIdForUser(wallet)`.
- If the returned position ID is `0`, skip health-factor checks for that wallet.
- If the returned position ID is non-zero, call `getUserForPositionId(positionId)` as an optional consistency check.
- If `getUserForPositionId(positionId)` does not match the app wallet, update the cached position owner or flag the record for investigation.

Data model:

```text
user_position_cache
- user_id
- wallet_address
- position_id
- owner_address_onchain
- last_resolved_at
- status
- updated_at
```

### User Contact Resolution

The service must use existing app user records for contact information.

Data model:

```text
users
- id
- wallet_address
- email
- push_token
- telegram_id
- notification_preferences
- created_at
- updated_at
```

Rules:

- Normalize wallet addresses to lowercase.
- If a user has no wallet address, skip the user.
- If a user has a wallet address but no position, skip health-factor notification.
- If a user has no verified contact method, store the risk snapshot but skip notification.
- Users must be able to opt out of non-critical notifications.

### Health Factor Monitoring

For each app user with a resolved non-zero position ID, call:

```solidity
getHealthFactor(positionId, 0)
getPositionBorrowedValue(positionId)
getTotalActiveDebt(positionId)
isLiquidatable(positionId)
```

Classify risk:

```text
Healthy:      healthFactor >= 1.5e18
Warning:      1.2e18 <= healthFactor < 1.5e18
Urgent:       1.0e18 <= healthFactor < 1.2e18
Liquidatable: isLiquidatable(positionId) == true
```

Thresholds must be configurable.

Data model:

```text
position_risk_snapshots
- id
- user_id
- position_id
- owner_address
- health_factor
- open_borrow_debt_value
- active_loan_debt_value
- is_liquidatable
- risk_level
- block_number
- checked_at
```

### Loan Monitoring

For each position:

```solidity
getUserActiveLoanIds(positionId)
```

For each loan:

```solidity
getLoanDetails(loanId)
getOutstandingDebtForLoan(loanId)
```

Data model:

```text
loans
- loan_id
- position_id
- token
- principal
- repaid
- tenure_seconds
- start_timestamp
- outstanding_debt
- annual_rate_bps
- penalty_rate_bps
- status
- updated_at
```

### Notification Engine

Notification types:

```text
HEALTH_WARNING
HEALTH_URGENT
LIQUIDATION_ELIGIBLE
POSITION_LIQUIDATED
```

Rate limits:

- Warning: once per 24 hours per position.
- Urgent: once per 6 hours per position.
- Liquidatable: once per 1 hour per position.
- Always notify if risk level worsens.

Data model:

```text
notifications
- id
- position_id
- owner_address
- notification_type
- channel
- recipient
- payload
- status
- error
- sent_at
- created_at
```

Notification payload:

- Position ID.
- Current health factor.
- Risk level.
- Open-ended debt value.
- Fixed-loan debt value.
- Liquidatable status.
- Recommended action: add collateral or repay debt.

## Backend Services

### User Position Resolver Worker

Responsibilities:

- Read active users from the app database.
- Resolve `wallet_address -> position_id` with `getPositionIdForUser`.
- Cache resolved position IDs.
- Skip wallets with no position.
- Optionally verify `position_id -> owner` with `getUserForPositionId`.

### Risk Worker

Responsibilities:

- Scan cached user positions on a schedule.
- Read health factor and debt state.
- Store risk snapshots.
- Emit internal risk threshold events.

Suggested interval:

```text
Normal mode: every 5 minutes
High volatility mode: every 30-60 seconds
```

### Notification Worker

Responsibilities:

- Consume risk threshold events.
- Resolve contact info.
- Apply rate limits.
- Send notifications.
- Store delivery status.

## Configuration

```text
CHAIN_ID
RPC_URL
DIAMOND_ADDRESS
ENABLE_NOTIFICATIONS=true
HEALTH_WARNING_THRESHOLD=1500000000000000000
HEALTH_URGENT_THRESHOLD=1200000000000000000
SCAN_INTERVAL_SECONDS=300
CONFIRMATION_BLOCKS=2
```

## API Endpoints

### `GET /positions/:positionId/risk`

Returns latest risk state.

### `GET /users/:address/positions`

Returns positions owned by a wallet.

### `POST /users/:address/notification-preferences`

Updates notification preferences.

### `GET /notifications`

Returns notification history.

## Notification Templates

### Warning

```text
Subject: Your hodl position health factor is getting low

Your position #{positionId} has a health factor of {healthFactor}. Consider adding collateral or repaying debt.
```

### Urgent

```text
Subject: Urgent: Your hodl position is close to liquidation

Your position #{positionId} has a health factor of {healthFactor}. It may become liquidatable if collateral prices fall or debt increases.
```

### Liquidatable

```text
Subject: Your Hodl position is liquidatable

Your position #{positionId} is currently liquidatable. A liquidator may repay your debt and seize collateral. Add collateral or repay immediately if possible.
```

## Observability

Metrics:

```text
positions_scanned_total
positions_warning_total
positions_urgent_total
positions_liquidatable_total
notifications_sent_total
notifications_failed_total
average_scan_duration_seconds
rpc_errors_total
```

## Edge Cases

- `getPositionIdForUser(address) == 0` means no position.
- A user may exist in the app database without a wallet address.
- A position may have collateral but no debt.
- A position may have open-ended debt, fixed-loan debt, or both.
- A position owner can change after position transfer.
- App wallet and on-chain position owner may temporarily disagree.
- User contact info may be missing or unverified.
- RPC providers may lag.

## MVP Scope

- Read users and wallet addresses from the app database.
- Resolve position IDs through `getPositionIdForUser`.
- Poll health factor and debt state.
- Send warning, urgent, and liquidatable notifications.
- Expose latest risk state through API.

## Acceptance Criteria

- Service reads active user wallets from the app database.
- Service resolves `wallet -> positionId` using `getPositionIdForUser`.
- Service skips users with no position.
- Service resolves `positionId -> risk state -> contact info`.
- Service stores latest health snapshots.
- Service notifies users when thresholds are crossed.
- Service rate-limits repeated notifications.
- Service does not execute liquidation transactions.

## Future Enhancement: Event Indexing

Event indexing can be added later if the product needs protocol-wide monitoring beyond app users.

Optional events:

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
