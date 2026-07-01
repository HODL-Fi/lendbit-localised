// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Yield — Data structures for per-token yield strategy configuration and per-position yield accounting
// `YieldStrategyConfig` holds the Aave pool/aToken wiring and accrual accumulators; `YieldPosition` tracks a position's principal and accrued yield.
struct YieldStrategyConfig {
    bool enabled;
    bool paused;
    address aavePool;
    address aToken;
    uint16 allocationBps;
    uint16 protocolShareBps;
    uint256 totalPrincipal;
    uint256 accYieldPerPrincipalRay;
    uint256 protocolAccrued;
    uint256 lastRecordedBalance;
}

struct YieldPosition {
    uint256 principal;
    uint256 userAccrued;
    uint256 entryAccYieldPerPrincipalRay;
}
