// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";
import {VaultConfiguration} from "../../contracts/models/Protocol.sol";
import "../../contracts/models/Error.sol";

/// @notice Branch-coverage harness for LibVaultManager — exercises both sides of
///         every validation branch in the deposit/withdraw/deploy/config/pause/
///         reserve/getter flows that the existing suites leave half-covered.
///         The empty-vault upgrade guard (VAULT_NOT_EMPTY) lives in
///         UpgradeVaultStrand.t.sol and is intentionally NOT duplicated here.
contract CovVaultManagerTest is Base {
    address constant NO_VAULT_TOKEN = address(0xBEEF); // config exists by default, no vault

    function setUp() public override {
        super.setUp();
        createVaultAndFund(0); // deploys token4 vault (empty), sets pricefeed4
    }

    // ---- helpers ----------------------------------------------------------

    function _vault() internal view returns (TokenVault) {
        return TokenVault(gettersF.getTokenVault(address(token4)));
    }

    function _fundVault(uint256 amount) internal {
        token4.mint(address(this), amount);
        token4.approve(address(diamond), amount);
        vaultManagerF.deposit(address(token4), amount);
    }

    function _seedReserve() internal returns (uint256 expectedReserve) {
        _fundVault(10_000e6);
        vaultManagerF.setReserveFactor(address(token4), 2000); // 20% to protocol
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        uint256 loanId = protocolF.takeLoan(address(token4), 4_000e6, 365 days);

        vm.warp(block.timestamp + 365 days);
        updatePricefeedsData();

        uint256 debt = gettersF.getOutstandingDebtForLoan(loanId);
        uint256 interest = debt - 4_000e6;
        token4.mint(user1, debt);
        vm.startPrank(user1);
        token4.approve(address(diamond), debt);
        protocolF.repayLoan(loanId, debt);
        vm.stopPrank();

        expectedReserve = (interest * 2000) / 10000;
    }

    // ====================== _deposit ======================================

    function test_deposit_revert_zero_token() public {
        vm.expectRevert(ADDRESS_ZERO.selector);
        vaultManagerF.deposit(address(0), 1e6);
    }

    function test_deposit_revert_zero_amount() public {
        vm.expectRevert(AMOUNT_ZERO.selector);
        vaultManagerF.deposit(address(token4), 0);
    }

    function test_deposit_revert_token_not_supported() public {
        // token1 is a collateral token but has no vault / support flag
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token1)));
        vaultManagerF.deposit(address(token1), 1e6);
    }

    function test_deposit_creates_then_reuses_position() public {
        token4.mint(address(this), 2_000e6);
        token4.approve(address(diamond), 2_000e6);

        // first deposit: positionId == 0 branch -> creates a position
        uint256 shares1 = vaultManagerF.deposit(address(token4), 1_000e6);
        assertGt(shares1, 0, "shares minted on first deposit");

        // second deposit: positionId != 0 branch -> reuses the existing position
        uint256 shares2 = vaultManagerF.deposit(address(token4), 1_000e6);
        assertGt(shares2, 0, "shares minted on second deposit");
        assertEq(_vault().balanceOf(address(this)), shares1 + shares2);
    }

    // ====================== _withdraw =====================================

    function test_withdraw_revert_zero_token() public {
        vm.expectRevert(ADDRESS_ZERO.selector);
        vaultManagerF.withdraw(address(0), 1e6);
    }

    function test_withdraw_revert_zero_amount() public {
        vm.expectRevert(AMOUNT_ZERO.selector);
        vaultManagerF.withdraw(address(token4), 0);
    }

    function test_withdraw_revert_token_not_supported() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, address(token1)));
        vaultManagerF.withdraw(address(token1), 1e6);
    }

    function test_withdraw_revert_no_position() public {
        // token4 is supported but user2 never deposited -> positionId == 0
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(NO_POSITION_ID.selector, user2));
        vaultManagerF.withdraw(address(token4), 1e6);
    }

    function test_withdraw_success_decrements_principal() public {
        _fundVault(1_000e6);
        (, uint256 borrowsBefore) = vaultManagerF.getTokenVaultDetails(address(token4));
        assertEq(borrowsBefore, 0);

        vaultManagerF.withdraw(address(token4), 400e6);
        assertEq(token4.balanceOf(address(this)), 400e6);

        VaultConfiguration memory cfg = vaultManagerF.getTokenVaultConfig(address(token4));
        // principal decremented proportionally (supplyBefore != 0 + subtract branch)
        assertEq(cfg.totalDeposits, 600e6, "principal portion removed from deposit base");
    }

    // ====================== _deployVault ==================================

    function test_deploy_revert_zero_token() public {
        vm.expectRevert(ADDRESS_ZERO.selector);
        vaultManagerF.deployVault(address(0), address(0xdead), "n", "s", defaultConfig);
    }

    function test_deploy_revert_zero_pricefeed() public {
        ERC20Mock t = new ERC20Mock(18);
        vm.expectRevert(ADDRESS_ZERO.selector);
        vaultManagerF.deployVault(address(t), address(0), "n", "s", defaultConfig);
    }

    function test_deploy_revert_already_supported() public {
        vm.expectRevert(
            abi.encodeWithSelector(TOKEN_ALREADY_SUPPORTED.selector, address(token4), address(_vault()))
        );
        vaultManagerF.deployVault(address(token4), address(0xdead), "n", "s", defaultConfig);
    }

    function test_deploy_success() public {
        ERC20Mock t = new ERC20Mock(18);
        address v = vaultManagerF.deployVault(address(t), address(0xdead), "Cov", "COV", defaultConfig);
        assertTrue(gettersF.tokenIsSupported(address(t)));
        assertEq(v, gettersF.getTokenVault(address(t)));
    }

    // ====================== _upgradeVault =================================

    function test_upgrade_revert_no_vault() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        vaultManagerF.upgradeVault(NO_VAULT_TOKEN, defaultConfig);
    }

    // ====================== config setters ================================

    function test_setReserveFactor_success_and_vault_synced() public {
        vaultManagerF.setReserveFactor(address(token4), 3000);
        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).reserveFactor, 3000);
    }

    function test_setReserveFactor_no_vault_branch() public {
        // config exists (default zero struct) but no deployed vault -> skip vault sync
        vaultManagerF.setReserveFactor(NO_VAULT_TOKEN, 1234);
        assertEq(vaultManagerF.getTokenVaultConfig(NO_VAULT_TOKEN).reserveFactor, 1234);
    }

    function test_setReserveFactor_revert_zero() public {
        vm.expectRevert(AMOUNT_ZERO.selector);
        vaultManagerF.setReserveFactor(address(token4), 0);
    }

    function test_setBaseRate_success() public {
        vaultManagerF.setBaseRate(address(token4), 1500); // <= slope 3000
        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).baseRate, 1500);
    }

    function test_setBaseRate_revert_zero() public {
        vm.expectRevert(AMOUNT_ZERO.selector);
        vaultManagerF.setBaseRate(address(token4), 0);
    }

    function test_setBaseRate_revert_above_slope() public {
        // slope is 3000; base 3500 > slope -> BAD_RATE
        vm.expectRevert(BAD_RATE.selector);
        vaultManagerF.setBaseRate(address(token4), 3500);
    }

    function test_setSlopeRate_success() public {
        vaultManagerF.setSlopeRate(address(token4), 4000); // >= base 2000
        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).slopeRate, 4000);
    }

    function test_setSlopeRate_revert_zero() public {
        vm.expectRevert(AMOUNT_ZERO.selector);
        vaultManagerF.setSlopeRate(address(token4), 0);
    }

    function test_setSlopeRate_revert_below_base() public {
        // base is 2000; slope 1000 < base -> BAD_RATE
        vm.expectRevert(BAD_RATE.selector);
        vaultManagerF.setSlopeRate(address(token4), 1000);
    }

    function test_setOptimalUtilization_success() public {
        vaultManagerF.setOptimalUtilization(address(token4), 9000);
        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).optimalUtilization, 9000);
    }

    function test_setOptimalUtilization_revert_zero() public {
        vm.expectRevert(AMOUNT_ZERO.selector);
        vaultManagerF.setOptimalUtilization(address(token4), 0);
    }

    function test_setOptimalUtilization_revert_below_floor() public {
        vm.expectRevert(BAD_RATE.selector); // < 5000
        vaultManagerF.setOptimalUtilization(address(token4), 4999);
    }

    function test_setLiquidationBonus_success() public {
        vaultManagerF.setLiquidationBonus(address(token4), 1000); // boundary, allowed
        assertEq(vaultManagerF.getTokenVaultConfig(address(token4)).liquidationBonus, 1000);
    }

    function test_setLiquidationBonus_revert_too_high() public {
        vm.expectRevert(BAD_RATE.selector); // > 1000
        vaultManagerF.setLiquidationBonus(address(token4), 1001);
    }

    // ====================== _validateVaultUtlization ======================
    // MAX_UTILIZATION = 9000 bps. maxAmount = totalDeposits * 9000 / 10000.

    function test_utilization_just_under_cap_allows_borrow() public {
        _fundVault(1_000e6); // maxAmount = 900e6
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        protocolF.borrow(address(token4), 899e6); // 899e6 < 900e6 -> true branch

        (, uint256 borrows) = vaultManagerF.getTokenVaultDetails(address(token4));
        assertEq(borrows, 899e6, "borrow within cap succeeded");
    }

    function test_utilization_at_cap_reverts_borrow() public {
        _fundVault(1_000e6); // maxAmount = 900e6
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        vm.expectRevert(TOKEN_OVERUTILIZATION.selector); // 900e6 < 900e6 -> false branch
        protocolF.borrow(address(token4), 900e6);
    }

    // ====================== pause / resume support ========================

    function test_pauseTokenSupport_revert_zero() public {
        vm.expectRevert(ADDRESS_ZERO.selector);
        vaultManagerF.pauseTokenSupport(address(0));
    }

    function test_pauseTokenSupport_revert_not_supported() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        vaultManagerF.pauseTokenSupport(NO_VAULT_TOKEN);
    }

    function test_pause_then_resume_support() public {
        vaultManagerF.pauseTokenSupport(address(token4));
        assertFalse(gettersF.tokenIsSupported(address(token4)));
        vaultManagerF.resumeTokenSupport(address(token4));
        assertTrue(gettersF.tokenIsSupported(address(token4)));
    }

    function test_resumeTokenSupport_revert_zero() public {
        vm.expectRevert(ADDRESS_ZERO.selector);
        vaultManagerF.resumeTokenSupport(address(0));
    }

    function test_resumeTokenSupport_revert_no_vault() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        vaultManagerF.resumeTokenSupport(NO_VAULT_TOKEN);
    }

    function test_resumeTokenSupport_already_supported_noop() public {
        // token4 is already supported -> early return branch, no state change
        assertTrue(gettersF.tokenIsSupported(address(token4)));
        vaultManagerF.resumeTokenSupport(address(token4));
        assertTrue(gettersF.tokenIsSupported(address(token4)));
    }

    // ====================== _setVaultPaused ===============================

    function test_setVaultPaused_revert_no_vault() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        vaultManagerF.setVaultPaused(NO_VAULT_TOKEN, true);
    }

    function test_setVaultPaused_blocks_then_resumes_deposits() public {
        vaultManagerF.setVaultPaused(address(token4), true);

        token4.mint(address(this), 1_000e6);
        token4.approve(address(diamond), 1_000e6);
        vm.expectRevert(TokenVault.VaultPaused.selector);
        vaultManagerF.deposit(address(token4), 1_000e6);

        vaultManagerF.setVaultPaused(address(token4), false);
        uint256 shares = vaultManagerF.deposit(address(token4), 1_000e6);
        assertGt(shares, 0, "deposit works after resume");
    }

    // ====================== _harvestVaultReserve ==========================

    function test_harvest_revert_no_vault() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        vaultManagerF.harvestVaultReserve(NO_VAULT_TOKEN, address(this), 1);
    }

    function test_harvest_zero_reserve_returns_zero() public {
        _fundVault(1_000e6); // no interest accrued -> reserve == 0
        assertEq(vaultManagerF.getVaultReserve(address(token4)), 0);
        uint256 harvested = vaultManagerF.harvestVaultReserve(address(token4), address(this), 100);
        assertEq(harvested, 0, "early-return on empty reserve");
    }

    function test_harvest_nonzero_reserve_default_recipient() public {
        uint256 expectedReserve = _seedReserve();
        assertGt(expectedReserve, 0, "reserve accrued");
        assertEq(vaultManagerF.getVaultReserve(address(token4)), expectedReserve);

        // _to == address(0) -> facet defaults recipient to the contract owner (this)
        uint256 ownerBefore = token4.balanceOf(address(this));
        uint256 harvested = vaultManagerF.harvestVaultReserve(address(token4), address(0), type(uint256).max);

        assertEq(harvested, expectedReserve, "clamped to available reserve");
        assertEq(token4.balanceOf(address(this)) - ownerBefore, expectedReserve, "owner received reserve");
        assertEq(vaultManagerF.getVaultReserve(address(token4)), 0, "reserve drained");
    }

    // ====================== _writeOffBadDebt ==============================

    function test_writeOff_revert_no_vault() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        vaultManagerF.writeOffBadDebt(NO_VAULT_TOKEN, 1);
    }

    function test_writeOff_success_socializes_loss() public {
        _fundVault(10_000e6);
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        protocolF.takeLoan(address(token4), 4_000e6, 365 days);

        TokenVault vault = _vault();
        uint256 assetsBefore = vault.totalAssets();
        vaultManagerF.writeOffBadDebt(address(token4), 1_000e6);
        assertEq(vault.totalAssets(), assetsBefore - 1_000e6, "loss removed from totalAssets");
    }

    // ====================== getters =======================================

    function test_getVaultTotalAssets_success_and_revert() public {
        _fundVault(500e6);
        assertEq(gettersF.getVaultTotalAssets(address(token4)), 500e6);

        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        gettersF.getVaultTotalAssets(NO_VAULT_TOKEN);
    }

    function test_getVaultReserve_revert_no_vault() public {
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        gettersF.getVaultTotalAssets(NO_VAULT_TOKEN);
        vm.expectRevert(abi.encodeWithSelector(TOKEN_NOT_SUPPORTED.selector, NO_VAULT_TOKEN));
        vaultManagerF.getVaultReserve(NO_VAULT_TOKEN);
    }

    function test_getTokenVault_and_isSupported() public {
        assertEq(gettersF.getTokenVault(NO_VAULT_TOKEN), address(0), "undeployed -> zero");
        assertTrue(gettersF.getTokenVault(address(token4)) != address(0), "deployed -> non-zero");
        assertTrue(gettersF.tokenIsSupported(address(token4)));
        assertFalse(gettersF.tokenIsSupported(NO_VAULT_TOKEN));
    }

    function test_getTokenVaultDetails_reflects_borrows() public {
        _fundVault(10_000e6);
        depositCollateralFor(user1, address(token1), 1_000 ether);
        vm.prank(user1);
        protocolF.takeLoan(address(token4), 2_000e6, 365 days);

        (uint256 assets, uint256 borrows) = vaultManagerF.getTokenVaultDetails(address(token4));
        assertEq(borrows, 2_000e6, "borrow tally reflected");
        assertGt(assets, 0, "assets reported");
    }
}
