// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {VaultConfiguration} from "../../contracts/models/Protocol.sol";
import {BAD_RATE, ADDRESS_NOT_WHITELISTED} from "../../contracts/models/Error.sol";

/// @notice PoCs for report 2026-07-01-233007 findings #7 (deploy/upgrade config
///         bounds) and #8 (blacklist must gate vault deposits).
contract VaultConfigAndBlacklistTest is Base {
    // ---- #7: deploy-time config bounds ----

    function test_deployVault_rejects_excessive_liquidationBonus() public {
        (address _tok, address _feed) = deployERC20ContractAndAddPriceFeed("BadBonus", 18, 100);
        VaultConfiguration memory _cfg = defaultConfig;
        _cfg.liquidationBonus = 1001; // > 10%, above the setter's cap
        vm.expectRevert(BAD_RATE.selector);
        vaultManagerF.deployVault(_tok, _feed, "xBad", "xBAD", _cfg);
    }

    function test_deployVault_rejects_excessive_reserveFactor() public {
        (address _tok, address _feed) = deployERC20ContractAndAddPriceFeed("BadRF", 18, 100);
        VaultConfiguration memory _cfg = defaultConfig;
        _cfg.reserveFactor = 10_001; // > 100%, would underflow the LP-interest split
        vm.expectRevert(BAD_RATE.selector);
        vaultManagerF.deployVault(_tok, _feed, "xBad", "xBAD", _cfg);
    }

    function test_deployVault_accepts_bounded_config() public {
        (address _tok, address _feed) = deployERC20ContractAndAddPriceFeed("OkTok", 18, 100);
        VaultConfiguration memory _cfg = defaultConfig;
        _cfg.liquidationBonus = 1000; // exactly 10%
        _cfg.reserveFactor = 10_000; // exactly 100%
        address _vault = vaultManagerF.deployVault(_tok, _feed, "xOk", "xOK", _cfg);
        assertTrue(_vault != address(0), "bounded config deploys");
    }

    // ---- #8: blacklist gates vault deposits ----

    function test_vaultDeposit_blocked_after_blacklist() public {
        createVaultAndFund(1_000e6); // deploys + funds the token4 vault

        // user1 (whitelisted in Base) opens a position via a vault deposit.
        token4.mint(user1, 300e6);
        vm.startPrank(user1);
        token4.approve(address(diamond), type(uint256).max);
        vaultManagerF.deposit(address(token4), 100e6);
        vm.stopPrank();

        // Governance blacklists user1.
        positionManagerF.blacklistAddress(user1);

        // A further vault deposit by the now-blacklisted (existing-position) user
        // must revert — previously only the create-new-position branch checked.
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(ADDRESS_NOT_WHITELISTED.selector, user1));
        vaultManagerF.deposit(address(token4), 100e6);
        vm.stopPrank();
    }
}
