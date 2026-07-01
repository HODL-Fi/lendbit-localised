// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Event — File-level events emitted across the protocol's facets and libraries
// Covers position lifecycle, token/collateral management, borrowing, loans, yield, and Chainlink Functions.
event PositionIdCreated(uint256 indexed positionId, address indexed user);

event PositionIdTransferred(uint256 indexed positionId, address indexed oldAddress, address indexed newAddress);

event SecurityCouncilSet(address _newCouncil);

event TokenAdded(address indexed asset, address indexed assetVault);

event TokenSupportChanged(address indexed asset, bool isSupported);

// Vault Events
event Deposit(uint256 indexed positionId, address indexed asset, uint256 amount);
event Withdrawal(uint256 indexed positionId, address indexed asset, uint256 amount);

event CollateralDeposited(uint256 indexed positionId, address indexed token, uint256 amount);
event CollateralWithdrawn(uint256 indexed positionId, address indexed token, uint256 amount);

event CollateralTokenAdded(address indexed token);
event CollateralTokenRemoved(address indexed token);
event CollateralTokenLTVUpdated(address indexed token, uint16 tokenOldLTV, uint16 tokenNewLTV);

event LocalCurrencyAdded(string currency);
event LocalCurrencyRemoved(string currency);

event BorrowComplete(uint256 indexed positionId, address indexed token, uint256 amount);
event Repay(uint256 indexed positionId, address indexed token, uint256 amount);
event PositionLiquidated(
    uint256 indexed positionId, address indexed liquidator, address indexed token, uint256 amountToLiquidate
);

// Loan Events
event InterestRateUpdated(uint16 newInterestRate, uint16 newPenaltyRate);
event LoanTaken(
    uint256 indexed positionId,
    uint256 indexed loanId,
    address indexed token,
    uint256 principal,
    uint256 tenureSeconds,
    uint16 annualRateBps
);
event LoanRepayment(uint256 indexed positionId, uint256 indexed loanId, address indexed token, uint256 amount);
event LoanLiquidated(
    uint256 indexed positionId,
    uint256 indexed loandId,
    address indexed token,
    address liquidator,
    uint256 amountLiquidated
);

event YieldTokenConfigured(
    address indexed token, address indexed pool, address indexed aToken, uint16 allocationBps, uint16 protocolShareBps
);
event YieldTokenPaused(address indexed token, bool paused);
event YieldAllocated(uint256 indexed positionId, address indexed token, uint256 amount);
event YieldReleased(uint256 indexed positionId, address indexed token, uint256 amount);
event YieldClaimed(uint256 indexed positionId, address indexed token, address indexed to, uint256 amount);
event ProtocolYieldHarvested(address indexed token, address indexed to, uint256 amount);
event YieldAccrued(address indexed token, uint256 userAmount, uint256 protocolAmount);

// Chainlink functions events
event RequestSent(bytes32 indexed id);

event RequestFulfilled(bytes32 indexed id);

event Response(bytes32 indexed requestId, uint256 priceData, bytes response, bytes err);

event FunctionsRouterChanged(address indexed securityCouncil, bytes32 donId, address router);

event FunctionsSourceChanged(address indexed securityCouncil, bytes source);

// Vault risk/rate parameter updates
event ReserveFactorSet(address indexed token, uint16 reserveFactor);
event BaseRateSet(address indexed token, uint16 baseRate);
event SlopeRateSet(address indexed token, uint16 slopeRate);
event OptimalUtilizationSet(address indexed token, uint16 optimalUtilization);
event LiquidationBonusSet(address indexed token, uint16 liquidationBonus);
