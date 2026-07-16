// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";

/// @notice Regression tests for the Track 2 (vault-side) fixes: M-09 (fixed-leg
///         invariant break after writeoff + floating repay) and M-04 (blacklist
///         bypass via LP-share transfer). These are staged for redeploy — the live
///         vaults cannot adopt them until they are empty — but they are fully
///         testable against a freshly deployed vault, which is what this harness does.
///
///         The test contract stands in as the diamond (satisfies `onlyDiamond`) and
///         implements the `isBlacklisted` view that TokenVault._update queries.
contract Track2VaultFixesTest is Test {
    ERC20Mock asset;
    TokenVault vault;

    // Blacklist state this test exposes to the vault as "the diamond".
    mapping(address => bool) internal _blacklist;

    function isBlacklisted(address user) external view returns (bool) {
        return _blacklist[user];
    }

    function setUp() public {
        asset = new ERC20Mock(18);
        // interestRate 20%, reserveFactor 10%; this contract is the diamond.
        vault = new TokenVault(address(asset), "vLBT", "vLBT", address(this), 2000, 1000);
    }

    // ---------------------------------------------------------------------
    // M-09 — floating repay must not leave fixedBorrows > totalBorrows, which
    // would accrue fixedRateProduct on phantom principal. Asserted via the
    // observable consequence (share-price accrual) rather than private slots:
    // if the invariant breaks, a year of accrual inflates from the true 300k
    // principal to the phantom 500k.
    // ---------------------------------------------------------------------

    /// @dev Sequence from the finding: 800k fixed + 200k floating, write off 500k,
    ///      then repay 200k of floating debt (totalBorrows -> 300k). Pre-fix the fixed
    ///      leg stayed at 500k, so fixedRateProduct kept accruing on 500k of phantom
    ///      principal; post-fix it is re-capped and scaled to 300k.
    function test_M09_floating_repay_no_phantom_interest_over_accrual() public {
        address borrower = makeAddr("borrower");
        asset.mint(address(vault), 1_000_000 ether); // liquidity to lend out

        vault.borrowFixed(borrower, 800_000 ether, 2000);
        vault.borrow(borrower, 200_000 ether);
        vault.updateBadDebt(500_000 ether); // writeoff caps fixed leg to 500k
        vault.repay(200_000 ether, 0); // floating repay -> totalBorrows 300k

        uint256 assetsBefore = vault.totalAssets();
        vm.warp(block.timestamp + 365 days);
        uint256 grew = vault.totalAssets() - assetsBefore;

        // Correct fixed accrual on 300k at 20%, net of 10% reserve = 300k*0.20*0.90 = 54k.
        // Phantom (pre-fix) accrual would be on 500k = 90k.
        assertApproxEqAbs(grew, 54_000 ether, 1 ether, "accrual must reflect the true 300k principal");
        assertLt(grew, 80_000 ether, "must not accrue on phantom 500k (M-09)");
    }

    // ---------------------------------------------------------------------
    // M-04 — blacklisted parties cannot move LP shares peer-to-peer.
    // ---------------------------------------------------------------------

    function _giveShares(address to, uint256 assets) internal {
        asset.mint(address(this), assets);
        asset.approve(address(vault), assets);
        vault.deposit(assets, to); // diamond deposit mints shares to `to`
    }

    function test_M04_blacklisted_holder_cannot_transfer_shares() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _giveShares(alice, 1_000 ether);

        // Council blacklists alice (tombstone visible via this contract's isBlacklisted).
        _blacklist[alice] = true;

        vm.prank(alice);
        vm.expectRevert(TokenVault.TransferNotAllowed.selector);
        vault.transfer(bob, 100 ether);
    }

    function test_M04_cannot_transfer_to_blacklisted_recipient() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _giveShares(alice, 1_000 ether);
        _blacklist[bob] = true;

        vm.prank(alice);
        vm.expectRevert(TokenVault.TransferNotAllowed.selector);
        vault.transfer(bob, 100 ether);
    }

    function test_M04_clean_parties_transfer_normally() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        _giveShares(alice, 1_000 ether);

        vm.prank(alice);
        vault.transfer(bob, 100 ether);
        assertEq(vault.balanceOf(bob), 100 ether, "clean peer transfer must succeed");
    }

    /// @dev Deposit (mint) and withdraw (burn) are NOT gated by _update — they route
    ///      through the diamond, which already enforces the freeze. A blacklisted
    ///      holder minting via the diamond deposit path is unaffected by this hook.
    function test_M04_mint_and_burn_not_gated_by_transfer_hook() public {
        address alice = makeAddr("alice");
        _blacklist[alice] = true;

        // Mint (from == address(0)) is allowed by the hook even for a blacklisted `to`.
        _giveShares(alice, 500 ether);
        assertEq(vault.balanceOf(alice), 500 ether, "diamond mint path not blocked by _update");
    }
}
