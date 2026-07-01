// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

/// @dev USDT-style token: transfer/transferFrom/approve return NOTHING.
contract NoReturnToken {
    string public name = "Tether";
    string public symbol = "USDT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external {
        allowance[msg.sender][spender] = amt;
    }
}

/// @dev Fee-on-transfer token: recipient receives 1% less than sent.
contract FeeOnTransferToken {
    string public name = "FeeToken";
    string public symbol = "FEE";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function _move(address from, address to, uint256 amt) internal {
        uint256 fee = amt / 100;
        balanceOf[from] -= amt;
        balanceOf[to] += amt - fee; // recipient gets less
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _move(from, to, amt);
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }
}

/// @notice Finding #13: the vault deposit path now uses SafeERC20 + balance-diff,
///         so no-bool-return tokens (USDT) deposit fine and fee-on-transfer tokens
///         credit the amount actually received.
contract WeirdTokenDepositTest is Base {
    function _deployVaultFor(address _token) internal {
        MockV3Aggregator feed = new MockV3Aggregator(8, 1e8); // $1
        vaultManagerF.deployVault(_token, address(feed), "xWeird", "xWRD", defaultConfig);
    }

    function test_usdt_style_no_return_token_deposits() public {
        NoReturnToken usdt = new NoReturnToken();
        _deployVaultFor(address(usdt));

        usdt.mint(user1, 1_000e6);
        vm.startPrank(user1);
        usdt.approve(address(diamond), 1_000e6);
        // pre-fix this reverted on the raw transferFrom bool-decode
        vaultManagerF.deposit(address(usdt), 1_000e6);
        vm.stopPrank();

        assertEq(vaultManagerF.getTokenVaultConfig(address(usdt)).totalDeposits, 1_000e6);
    }

    function test_fee_on_transfer_credits_received_not_nominal() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        _deployVaultFor(address(fee));

        fee.mint(user1, 1_000e6);
        vm.startPrank(user1);
        fee.approve(address(diamond), 1_000e6);
        vaultManagerF.deposit(address(fee), 1_000e6);
        vm.stopPrank();

        // 1% fee on the user->diamond transfer → totalDeposits credits the
        // received 990, not the nominal 1,000 (no over-count of liquidity).
        assertEq(vaultManagerF.getTokenVaultConfig(address(fee)).totalDeposits, 990e6);
    }
}
