// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @notice Interface for Vault Manager
 */
/// @title IVaultManager — Interface for notifying the protocol of vault deposits, withdrawals, and transfers
interface IVaultManager {
    /// @notice Notifies the vault manager of a deposit of `amount` of `asset` by `depositor`, optionally transferring the assets.
    function notifyVaultDeposit(address asset, uint256 amount, address depositor, bool transferAssets) external;
    /// @notice Notifies the vault manager of a withdrawal of `amount` of `asset` to `receiver`, optionally transferring the assets.
    function notifyVaultWithdrawal(address asset, uint256 amount, address receiver, bool transferAssets) external;
    /// @notice Notifies the vault manager of a transfer of `amount` of `asset` from `sender` to `receiver`.
    function notifyVaultTransfer(address asset, uint256 amount, address sender, address receiver)
        external
        returns (bool);
    /// @notice Returns the current exchange rate for the vault holding `asset`.
    function getVaultExchangeRate(address asset) external view returns (uint256);
    /// @notice Returns the total assets held by the vault for `asset`.
    function getVaultTotalAssets(address asset) external view returns (uint256);
}
