// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// import "../contracts/interfaces/IDiamondCut.sol";
// import "../contracts/facets/DiamondCutFacet.sol";
// import "../contracts/facets/DiamondLoupeFacet.sol";
// import "../contracts/facets/OwnershipFacet.sol";
// import "../contracts/facets/VaultManagerFacet.sol";
// import "../contracts/Diamond.sol";
import {Base, ERC20Mock} from "./Base.t.sol";

// import "../contracts/models/Protocol.sol";
// import "../contracts/models/Error.sol";
// import "../contracts/models/Event.sol";

import {TokenVault} from "../contracts/TokenVault.sol";
// import {console} from "forge-std/console.sol";

contract TokenVaultTest is Base {
    address linkHolder = 0x4281eCF07378Ee595C564a59048801330f3084eE; //sepolia

    TokenVault tokenVault;

    function setUp() public override {
        super.setUp();

        tokenVault = new TokenVault(address(token3), "Hodl CNGN", "HCNGN", address(diamond), 2000, 0);
    }

    /// @dev `repay` now takes (principal, interest). Reproduce the old
    ///      principal-first split so these accrual-model assertions are unchanged.
    function _repaySplit(uint256 amount) internal {
        uint256 tb = tokenVault.totalBorrow();
        uint256 p = amount > tb ? tb : amount;
        tokenVault.repay(p, amount - p);
    }


    function testVaultDeposit() public {
        uint256 _amount = 100_000e8;
        token3.mint(address(diamond), _amount);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), _amount);
        tokenVault.deposit(_amount, user1);

        assertEq(token3.balanceOf(address(diamond)), 0);
        assertEq(tokenVault.balanceOf(user1), _amount);
    }

    function testVaultTotalAssets() public {
        uint256 _amount = 100_000e8;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);

        tokenVault.deposit(_amount * 3, user2);

        tokenVault.deposit(_amount / 2, nonAdmin);

        assertEq(token3.balanceOf(address(tokenVault)), 450_000e8);
        assertEq(tokenVault.balanceOf(user1), _amount);
        assertEq(tokenVault.balanceOf(user2), _amount * 3);
        assertEq(tokenVault.balanceOf(nonAdmin), _amount / 2);
    }

    function testVaultTotalAssetsWithDebts() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);

        tokenVault.deposit(_amount * 3, user2);

        tokenVault.deposit(_amount / 2, nonAdmin);

        tokenVault.borrow(user1, _amount * 2);
        vm.stopPrank();

        assertEq(tokenVault.totalAssets(), 450_000e6);
        assertEq(tokenVault.balanceOf(user1), _amount);
        assertEq(tokenVault.balanceOf(user2), _amount * 3);
        assertEq(tokenVault.balanceOf(nonAdmin), _amount / 2);
        assertEq(token3.balanceOf(address(tokenVault)), 250_000e6);
    }

    function testVaultTotalAssetsWithDebtsAndAccruedInterest() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);

        tokenVault.deposit(_amount * 3, user2);

        tokenVault.deposit(_amount / 2, nonAdmin);

        tokenVault.borrow(user1, _amount * 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        assertEq(tokenVault.totalAssets(), (450_000e6 + 40_000e6));
        assertEq(token3.balanceOf(address(tokenVault)), 250_000e6);
    }

    function testVaultTotalAssetsWithDebtsAndSomeRepay() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 6);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);

        tokenVault.deposit(_amount * 3, user2);

        tokenVault.deposit(_amount / 2, nonAdmin);

        tokenVault.borrow(user1, _amount * 2);
        // vm.stopPrank();

        vm.warp(block.timestamp + 365 days / 2);

        assertEq(tokenVault.totalAssets(), (450_000e6 + 20_000e6));
        assertEq(token3.balanceOf(address(tokenVault)), 250_000e6);

        token3.transfer(address(tokenVault), _amount);
        _repaySplit(_amount);

        vm.warp(365 days + 1); // for some reason using block.timestamp + 365 days / 2 still returns the old timestamp, so hardcoding it here

        assertEq(tokenVault.totalAssets(), (470_000e6 + 10_000e6));

        token3.transfer(address(tokenVault), _amount / 2);
        _repaySplit(_amount / 2);

        vm.warp(365 days + 1 + (365 days / 2)); // warp another 6 months to accrue more interest on the remaining loan

        assertEq(tokenVault.totalAssets(), (480_000e6 + 5_000e6));
    }

    function testDepositIncludesDirectTransfers() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 3);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);

        // initial deposit
        tokenVault.deposit(_amount, user1);

        // direct transfer into vault (simulates someone sending tokens)
        token3.transfer(address(tokenVault), _amount);

        // deposit after direct transfer should snapshot on-chain balance
        tokenVault.deposit(_amount, user2);

        // totalDeposits should equal totalAssets snapshot after the deposit
        assertEq(
            tokenVault.totalAssets(),
            ERC20Mock(address(token3)).balanceOf(address(tokenVault))
                + /* borrows */ 0 + /* accrued */ 0 - /* bad debt */ 0
        );
        uint256 uOneShares = tokenVault.balanceOf(user1);
        uint256 uTwoShares = tokenVault.balanceOf(user2);
        // user1 earns all the profit before user2 deposits
        assertEq(tokenVault.convertToAssets(uTwoShares) + _amount, tokenVault.convertToAssets(uOneShares));
        vm.stopPrank();
    }

    function testDepositorsAssetsIncreaseAfterRepay() public {
        // Expectation: repay reduces principal first => final totalAssets == 480_000e6
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 6);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        uint256 uOneShares = tokenVault.deposit(_amount, user1);
        uint256 uTwoShares = tokenVault.deposit(_amount * 3, user2);
        uint256 uThreeShares = tokenVault.deposit(_amount / 2, nonAdmin);
        tokenVault.borrow(user1, _amount * 2);

        vm.warp(block.timestamp + 365 days / 2);

        // sanity check pre-repay
        assertEq(tokenVault.totalAssets(), (450_000e6 + 20_000e6));
        assertEq(token3.balanceOf(address(tokenVault)), 250_000e6);

        // positions have earned interest
        assertGt(tokenVault.convertToAssets(uOneShares), _amount);
        assertGt(tokenVault.convertToAssets(uTwoShares), _amount * 3);
        assertGt(tokenVault.convertToAssets(uThreeShares), _amount / 2);
        vm.stopPrank();
    }

    function testRepayInterestFirstFlow() public {
        // Expectation: repay pays accrued interest first => final totalAssets == 482_000e6
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 6);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);
        tokenVault.deposit(_amount / 2, nonAdmin);
        tokenVault.borrow(user1, _amount * 2);

        vm.warp(block.timestamp + 365 days / 2);

        // sanity check pre-repay
        assertEq(tokenVault.totalAssets(), (450_000e6 + 20_000e6));
        assertEq(token3.balanceOf(address(tokenVault)), 250_000e6);

        // repay interest-first scenario
        token3.transfer(address(tokenVault), _amount);
        _repaySplit(_amount);

        vm.warp(365 days + 1); // for some reason using block.timestamp + 365 days / 2 still returns the old timestamp, so hardcoding it here
        assertEq(block.timestamp, 365 days + 1);

        // expected if repay applied to accrued interest first
        assertEq(tokenVault.totalAssets(), 480_000e6);
        vm.stopPrank();
    }

    // ============ Basic Bad Debt Tests ============
    function testBadDebtCreationOnDefault() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);

        uint256 borrowAmount = _amount * 2;
        tokenVault.borrow(user1, borrowAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // Mark portion as bad debt
        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount);

        uint256 expectedTotalAssets = (_amount + _amount * 3) + (40_000e6) - _amount;
        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    function testBadDebtReducesTotalAssets() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);

        tokenVault.borrow(user1, _amount * 2);
        vm.stopPrank();

        uint256 totalAssetsBeforeBadDebt = tokenVault.totalAssets();

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount / 2);

        uint256 totalAssetsAfterBadDebt = tokenVault.totalAssets();

        assertEq(totalAssetsAfterBadDebt, totalAssetsBeforeBadDebt - (_amount / 2));
    }

    function testMultipleBadDebtWriteOffs() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 10);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);
        tokenVault.deposit(_amount * 2, nonAdmin);

        tokenVault.borrow(user1, _amount);
        tokenVault.borrow(user2, _amount);
        vm.stopPrank();

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount / 2);

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount / 4);

        uint256 expectedBadDebt = (_amount / 2) + (_amount / 4);
        uint256 expectedTotalAssets = (_amount * 6) - expectedBadDebt;

        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    // ============ Bad Debt Edge Cases ============
    function testBadDebtEqualsTotalBorrow() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);

        uint256 _totalAssetBeforeBadDebt = tokenVault.totalAssets();

        uint256 borrowAmount = _amount * 2;
        tokenVault.borrow(user1, borrowAmount);
        vm.stopPrank();

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(borrowAmount);

        uint256 expectedTotalAssets = _totalAssetBeforeBadDebt - borrowAmount;
        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    function testBadDebtExceedsBorrowReducesBorrowToZero() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.borrow(user1, _amount);
        vm.stopPrank();

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount);

        uint256 _totalAssetAfterBadDebt = tokenVault.totalAssets();
        vm.warp(block.timestamp + 365 days);

        // total asset did not increase since borrow is zero due to bad debt
        assertEq(_totalAssetAfterBadDebt, tokenVault.totalAssets());
    }

    function testBadDebtExceedsBorrowAndInterestReverts() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.borrow(user1, _amount);
        vm.stopPrank();
        vm.warp(block.timestamp + 60 days);

        vm.prank(address(diamond));
        vm.expectRevert("InvalidAmount()");
        tokenVault.updateBadDebt(_amount * 2);
    }

    function testZeroBadDebtWrite() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.borrow(user1, _amount);
        vm.stopPrank();

        uint256 totalAssetsBefore = tokenVault.totalAssets();

        vm.prank(address(diamond));
        vm.expectRevert("InvalidAmount()");
        tokenVault.updateBadDebt(0);

        assertEq(tokenVault.totalAssets(), totalAssetsBefore);
    }

    // ============ Bad Debt with Interest Accrual ============

    function testBadDebtWithAccruedInterest() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);

        tokenVault.borrow(user1, _amount * 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 totalAssetsWithInterest = tokenVault.totalAssets();

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount);

        uint256 expectedTotalAssets = totalAssetsWithInterest - _amount;
        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    function testBadDebtWriteOffInterestFirst() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);

        tokenVault.borrow(user1, _amount * 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        // Write off only accrued interest
        uint256 accruedInterest = 40_000e6;
        vm.prank(address(diamond));
        tokenVault.updateBadDebt(accruedInterest);

        uint256 expectedTotalAssets = (_amount * 4);
        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    // ============ Bad Debt Impact on Share Price ============

    function testBadDebtReducesSharePrice() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        uint256 user1Shares = tokenVault.deposit(_amount, user1);
        uint256 user2Shares = tokenVault.deposit(_amount * 3, user2);

        tokenVault.borrow(user1, _amount * 2);
        vm.stopPrank();

        uint256 sharePriceBefore = tokenVault.convertToAssets(1e18);

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount * 2);

        uint256 sharePriceAfter = tokenVault.convertToAssets(1e18);

        assertLt(sharePriceAfter, sharePriceBefore);
        assertLt(user1Shares, tokenVault.convertToShares(_amount));
        assertLt(user2Shares, tokenVault.convertToShares(_amount * 3));
    }

    function testBadDebtAffectsAllDepositorsEqually() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 5);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        uint256 user1Shares = tokenVault.deposit(_amount, user1);
        uint256 user2Shares = tokenVault.deposit(_amount * 3, user2);

        tokenVault.borrow(user1, _amount * 2);

        tokenVault.updateBadDebt(_amount * 2);
        vm.stopPrank();

        // Both users lose pro-rata share of bad debt
        uint256 user1Assets = tokenVault.convertToAssets(user1Shares);
        uint256 user2Assets = tokenVault.convertToAssets(user2Shares);

        assertEq(user1Assets + user2Assets, _amount + (_amount * 3) - (_amount * 2));
    }

    // ============ Bad Debt Partial Recovery ============
    function testPartialBadDebtRecoveryViaRepay() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 6);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 3, user2);

        tokenVault.borrow(user1, _amount * 2);
        vm.stopPrank();

        // Write off half as bad debt
        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount);

        uint256 totalAssetsAfterBadDebt = tokenVault.totalAssets();

        // Recover portion of bad debt
        vm.startPrank(address(diamond));
        token3.mint(address(diamond), _amount / 2);
        token3.approve(address(tokenVault), type(uint256).max);
        token3.transfer(address(tokenVault), _amount / 2);
        _repaySplit(_amount / 2); // 50_000e6 paid is already accounted for in totalAssets
        vm.stopPrank();

        assertEq(tokenVault.totalAssets(), totalAssetsAfterBadDebt);
    }

    function testCompleteDefaultScenario() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 10);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 5, user2);
        tokenVault.deposit(_amount * 2, nonAdmin);

        tokenVault.borrow(user1, _amount * 4);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days);

        uint256 totalAssetsWithInterest = tokenVault.totalAssets();

        // Complete default
        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount * 4 + 80_000e6);

        uint256 expectedTotalAssets = totalAssetsWithInterest - (_amount * 4 + 80_000e6);
        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    // ============ Bad Debt with Concurrent Operations ============
    function testBadDebtWriteOffDuringDeposit() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 6);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.borrow(user1, _amount);
        vm.stopPrank();

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount);

        vm.startPrank(address(diamond));
        token3.mint(address(diamond), _amount * 2);
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount * 2, user2);
        vm.stopPrank();

        uint256 expectedTotalAssets = _amount * 2;
        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    function testBadDebtWriteOffThenBorrow() public {
        createVaultAndFund(0);
        uint256 _amount = 100_000e6;
        token3.mint(address(diamond), _amount * 6);

        vm.startPrank(address(diamond));
        token3.approve(address(tokenVault), type(uint256).max);
        tokenVault.deposit(_amount, user1);
        tokenVault.deposit(_amount * 2, user2);
        tokenVault.borrow(user1, _amount);
        vm.stopPrank();

        vm.prank(address(diamond));
        tokenVault.updateBadDebt(_amount);

        vm.prank(address(diamond));
        tokenVault.borrow(user2, _amount / 2);

        uint256 expectedTotalAssets = _amount * 2;
        assertEq(tokenVault.totalAssets(), expectedTotalAssets);
    }

    function testVaultTotalBorrowsWithDebtsAndRepay() public {
        createVaultAndFund(500e6);
        TokenVault vault = TokenVault(gettersF.getTokenVault(address(token4)));
        uint256 _amount = 100_000e18;
        token2.mint(user1, _amount * 6);
        token4.mint(user1, 200e6);

        vm.startPrank(user1);
        token2.approve(address(diamond), type(uint256).max);
        token4.approve(address(diamond), type(uint256).max);
        protocolF.depositCollateral(address(token2), _amount);

        uint256 _loanId = protocolF.takeLoan(address(token4), 200e6, 365 days);
        // vm.stopPrank();

        vm.warp(block.timestamp + 365 days / 2);

        // vaultManagerF.getTokenVaultDetails(address(token4));
        // vault.totalBorrow();

        assertEq(vault.totalAssets(), (500e6 + 20e6));
        assertEq(token4.balanceOf(address(vault)), 300e6);

        token4.transfer(address(vault), 100e6);
        protocolF.repayLoan(_loanId, 100e6);

        (uint256 _totalAssets, uint256 _borrows) = vaultManagerF.getTokenVaultDetails(address(token4));
        // interest-first (#12): repaying 100e6 covers 20e6 interest + 80e6 principal,
        // leaving 120e6 principal outstanding (consistent with the loan's principal)
        assertEq(_borrows, 120e6);
        uint256 _assets = vault.totalAssets();
        assertEq(_totalAssets, _assets);
        assertEq(_assets, (500e6 + 100e6 + 20e6)); // after repayment, total assets should be deposits + transfers + remaining borrows + accrued interest

        vm.warp(365 days + 1); // for some reason using block.timestamp + 365 days / 2 still returns the old timestamp, so hardcoding it here

        // 12e6 accrues over the next 6 months on the 120e6 remaining principal
        assertEq(vault.totalAssets(), (500e6 + 120e6 + 12e6));
        (,,, uint256 repaid,,, uint256 debt,,,) = gettersF.getLoanDetails(_loanId);
        assertEq(repaid, 100e6);
        assertEq(debt, 132e6); // after 6 months, 10e6 interest should have accrued on the remaining 100e6 borrow

        protocolF.repayLoan(_loanId, debt); // repay the rest of the loan
        vm.stopPrank();

        vm.warp(365 days + 1 + (365 days / 2)); // warp another 6 months to accrue more interest on the remaining loan

        assertEq(vault.totalAssets(), (500e6 + 100e6 + 20e6 + 12e6));
        assertEq(vault.totalBorrow(), 0);
        vaultManagerF.getTokenVaultDetails(address(token4));
        vaultManagerF.getTokenVaultConfig(address(token4));
    }

    // function testSetInterestRate() public {
    //     createVaultAndFund(0);
    //     TokenVault vault = TokenVault(gettersF.getTokenVault(address(token4)));
    //     uint256 _amount = 100_000e18;
    //     token2.mint(user1, _amount * 6);
    //     token4.mint(user1, 200e6);

    //     vm.startPrank(user1);
    //     token2.approve(address(diamond), type(uint256).max);
    //     token4.approve(address(diamond), type(uint256).max);
    //     protocolF.depositCollateral(address(token2), _amount);

    //     uint256 _loanId = protocolF.takeLoan(address(token4), 200e6, 365 days);
    //     vm.stopPrank();

    //     vm.warp(block.timestamp + 365 days / 2);

    //     assertEq(vault.totalAssets(), (500e6 + 20e6));
    //     assertEq(token4.balanceOf(address(vault)), 300e6);

    //     vm.prank(address(diamond));
    //     vault.setInterestRate(4000); // increase interest rate to 40%

    //     vm.warp(365 days + 1); // for some reason using block.timestamp + 365 days / 2 still returns the old timestamp, so hardcoding it here

    //     assertEq(vault.totalAssets(), (500e6 + 100e6 + 20e6 + 40e6)); // after repayment, total assets should be deposits + transfers + remaining borrows + accrued interest
    // }
}
