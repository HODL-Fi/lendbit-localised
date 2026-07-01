// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";
import {VaultConfiguration} from "../../contracts/models/Protocol.sol";
import {VAULT_NOT_EMPTY} from "../../contracts/models/Error.sol";

/// @notice Finding #10: `_upgradeVault` deploys a fresh empty vault and overwrites
///         the pointer without migrating the old vault's assets, shares, or
///         borrows — permanently stranding every pre-upgrade deposit. The fix
///         blocks the swap whenever the old vault still holds shares or borrows,
///         so the contract can only be replaced while empty (pre-launch or after
///         a full drain). Config tweaks use the dedicated in-place setters.
contract UpgradeVaultStrandTest is Base {
    address lp = makeAddr("lp_strand");
    address borrower = makeAddr("borrower_strand");

    function _config() internal {
        createVaultAndFund(0); // deploy token4 vault, no initial fund
        positionManagerF.whitelistAddress(lp);
        positionManagerF.whitelistAddress(borrower);
    }

    function _lpDeposit(uint256 amt) internal {
        token4.mint(lp, amt);
        vm.startPrank(lp);
        token4.approve(address(diamond), amt);
        vaultManagerF.deposit(address(token4), amt);
        vm.stopPrank();
    }

    /// @dev With deposits outstanding, an upgrade would strand them — now it reverts.
    function test_upgrade_with_deposits_reverts() public {
        _config();
        _lpDeposit(1_000e6);

        TokenVault oldVault = TokenVault(gettersF.getTokenVault(address(token4)));
        uint256 shares = oldVault.totalSupply();
        assertGt(shares, 0, "LP holds shares in the old vault");

        // pre-fix this returned a new empty vault and orphaned the 1,000e6 deposit
        vm.expectRevert(abi.encodeWithSelector(VAULT_NOT_EMPTY.selector, shares, 0));
        vaultManagerF.upgradeVault(address(token4), defaultConfig);

        // pointer unchanged, funds still reachable through the same vault
        assertEq(gettersF.getTokenVault(address(token4)), address(oldVault), "vault pointer untouched");
    }

    /// @dev Outstanding borrows also block the swap (loans were funded from the old vault).
    function test_upgrade_with_borrows_reverts() public {
        _config();
        _lpDeposit(1_000e6);

        // LP withdraws nothing; borrower draws against the pool so totalBorrows > 0
        depositCollateralFor(borrower, address(token1), 1_000 ether);
        vm.prank(borrower);
        protocolF.borrow(address(token4), 100e6);

        TokenVault vault = TokenVault(gettersF.getTokenVault(address(token4)));
        uint256 shares = vault.totalSupply();
        uint256 borrows = vaultManagerF.getTokenVaultConfig(address(token4)).totalBorrows;
        assertGt(borrows, 0, "pool has outstanding borrows");

        vm.expectRevert(abi.encodeWithSelector(VAULT_NOT_EMPTY.selector, shares, borrows));
        vaultManagerF.upgradeVault(address(token4), defaultConfig);
    }

    /// @dev The legitimate path still works: an empty vault can be swapped.
    function test_upgrade_empty_vault_succeeds() public {
        _config(); // vault deployed, never deposited into -> empty

        TokenVault oldVault = TokenVault(gettersF.getTokenVault(address(token4)));
        address newVault = vaultManagerF.upgradeVault(address(token4), defaultConfig);

        assertTrue(newVault != address(oldVault), "empty vault was replaced");
        assertEq(gettersF.getTokenVault(address(token4)), newVault, "pointer now references the new vault");
    }
}
