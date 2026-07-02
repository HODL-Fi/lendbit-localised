// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";
import {AMOUNT_MISMATCH} from "../../contracts/models/Error.sol";

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
        TokenVault v = TokenVault(gettersF.getTokenVault(address(fee)));

        fee.mint(user1, 1_000e6);
        vm.startPrank(user1);
        fee.approve(address(diamond), 1_000e6);
        vaultManagerF.deposit(address(fee), 1_000e6);
        vm.stopPrank();

        // The token charges 1% on EACH hop: 1,000 → 990 (user→diamond) → 980.1
        // (diamond→vault). `totalDeposits` must credit what the VAULT actually
        // holds (980.1), not the diamond's first-hop receipt (990) — otherwise the
        // utilization cap is measured against liquidity that isn't there (#4).
        uint256 _totalDeposits = vaultManagerF.getTokenVaultConfig(address(fee)).totalDeposits;
        assertEq(_totalDeposits, 980_100_000, "credits the vault's real second-hop receipt");
        assertEq(_totalDeposits, fee.balanceOf(address(v)), "totalDeposits == actual vault balance (no over-count)");
    }

    /// @notice #5: the vault mints shares from what it ACTUALLY receives on the
    ///         diamond→vault hop, so a fee-on-transfer token never mints shares
    ///         beyond the vault's real asset backing.
    function test_fee_on_transfer_vault_does_not_overmint_shares() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        _deployVaultFor(address(fee));
        TokenVault v = TokenVault(gettersF.getTokenVault(address(fee)));

        fee.mint(user1, 1_000e6);
        vm.startPrank(user1);
        fee.approve(address(diamond), 1_000e6);
        vaultManagerF.deposit(address(fee), 1_000e6);
        vm.stopPrank();

        // Shares minted are backed 1:1 by assets the vault holds — no phantom
        // shares (pre-fix it minted `previewDeposit(990)` while holding only ~980).
        assertEq(v.totalSupply(), fee.balanceOf(address(v)), "first deposit: shares == received assets");
        assertLe(v.totalSupply(), fee.balanceOf(address(v)), "shares never exceed asset backing");
    }

    /// @notice #6: repayment books debt/vault accounting against the amount the
    ///         vault actually receives, so a fee-on-transfer shortfall fails closed
    ///         rather than crediting the borrower more than the LPs got.
    function test_fee_on_transfer_repay_reverts_on_shortfall() public {
        FeeOnTransferToken fee = new FeeOnTransferToken();
        _deployVaultFor(address(fee));

        // Fund the vault with LP liquidity so the borrow can be disbursed.
        fee.mint(address(this), 1_000e6);
        fee.approve(address(vaultManagerF), 1_000e6);
        vaultManagerF.deposit(address(fee), 1_000e6);

        // Collateralize user1 and open an open-ended borrow of the FoT token.
        depositCollateralFor(user1, address(token1), 10_000e18);
        vm.prank(user1);
        protocolF.borrow(address(fee), 100e6);

        // Repaying 100e6 delivers only 99e6 to the vault (1% fee) → revert.
        fee.mint(user1, 200e6);
        vm.startPrank(user1);
        fee.approve(address(diamond), 200e6);
        vm.expectRevert(abi.encodeWithSelector(AMOUNT_MISMATCH.selector, 99e6, 100e6));
        protocolF.repay(address(fee), 100e6);
        vm.stopPrank();
    }
}
