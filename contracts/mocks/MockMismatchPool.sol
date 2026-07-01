// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev A mock that implements getReserveAToken but always returns a wrong address.
///      Used to test the POOL_TOKEN_MISMATCH revert path in LibYieldStrategy._configureYieldToken.
contract MockMismatchPool {
    address public immutable wrongAToken;

    constructor(address _wrongAToken) {
        wrongAToken = _wrongAToken;
    }

    /// @dev Always returns `wrongAToken`, regardless of the asset supplied.
    function getReserveAToken(address) external view returns (address) {
        return wrongAToken;
    }
}

/// @dev A mock whose getReserveAToken always reverts with a custom message.
///      Used to test the BAD_POOL_ADDRESS revert path: calling a contract that
///      reverts inside getReserveAToken is caught by the try/catch in
///      LibYieldStrategy._configureYieldToken and re-thrown as BAD_POOL_ADDRESS.
///      An EOA cannot be used here because calling it returns empty bytes, causing
///      an ABI-decoding panic that Solidity's try/catch does NOT intercept.
contract MockRevertingPool {
    function getReserveAToken(address) external pure returns (address) {
        revert("MockRevertingPool: always reverts");
    }
}
