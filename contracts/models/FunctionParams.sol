// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// FunctionParams — Parameter structs used to pass grouped arguments between facet functions
// `RepayStateChangeParams` bundles the token, position, and amount applied during a repayment state change.
struct RepayStateChangeParams {
    address token;
    uint256 positionId;
    uint256 amount;
}
