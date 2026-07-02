// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base, MockV3Aggregator} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";

/// @notice End-to-end solvency check across the full lend → rate-change → repay →
///         liquidate lifecycle, stressing the changed math (#4 pro-rata
///         liquidation, #9 fixed-rate accrual). The core invariant asserted at
///         every step is the vault-solvency floor used by the property fuzzer:
///         `liquidBalance + totalBorrow() >= net LP principal` (interest only ever
///         adds to the asset side, so net principal is a safe floor).
contract LifecycleSolvencyTest is Base {
    TokenVault tvault;
    uint256 constant LP_DEPOSIT = 500e6;

    function _assertSolvent(string memory _step) internal view {
        uint256 liquid = token4.balanceOf(address(tvault));
        assertGe(liquid + tvault.totalBorrow(), LP_DEPOSIT, _step);
        // totalAssets must never revert and must stay >= LP principal.
        assertGe(tvault.totalAssets(), LP_DEPOSIT, string.concat(_step, " (totalAssets)"));
    }

    function test_lifecycle_solvency_lend_repay_liquidate() public {
        createVaultAndFund(LP_DEPOSIT);
        tvault = TokenVault(gettersF.getTokenVault(address(token4)));
        protocolF.setInterestRate(2000, 500); // 20% APR + 5% penalty
        _assertSolvent("after LP deposit");

        // Borrower opens a fixed loan against healthy collateral.
        uint256 _pid = depositCollateralFor(user1, address(token1), 5 ether); // ~$7,500
        vm.prank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), 20e6, 365 days); // ~$5,000
        _assertSolvent("after takeLoan");
        assertFalse(liquidationF.isLiquidatable(_pid), "healthy at origination");

        // Governance hikes the rate mid-loan; the fixed loan must be unaffected.
        protocolF.setInterestRate(4000, 500);
        vm.warp(block.timestamp + 180 days);
        updatePricefeedsData();
        _assertSolvent("after rate hike + 180d");
        assertFalse(liquidationF.isLiquidatable(_pid), "fixed loan stays healthy (accrues at 20%, not 40%)");

        // Partial voluntary repayment.
        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId);
        uint256 _partial = _debt / 3;
        token4.mint(user1, _partial);
        vm.startPrank(user1);
        token4.approve(address(diamond), _partial);
        protocolF.repayLoan(_loanId, _partial);
        vm.stopPrank();
        _assertSolvent("after partial repay");

        // Crash the collateral price to force the position underwater, then
        // partially liquidate the fixed loan (pro-rata path).
        MockV3Aggregator(pricefeed1).updateAnswer(300e8);
        assertTrue(liquidationF.isLiquidatable(_pid), "underwater after price crash");

        uint256 _debtNow = gettersF.getOutstandingDebtForLoan(_loanId);
        (,, uint256 _principalBefore,,,,,,,) = gettersF.getLoanDetails(_loanId);
        uint256 _liqPay = _debtNow / 2;
        address _liquidator = mkaddr("lifecycleLiquidator");
        token4.mint(_liquidator, _liqPay);
        vm.startPrank(_liquidator);
        token4.approve(address(liquidationF), _liqPay);
        liquidationF.liquidateLoan(_loanId, _liqPay, address(token1));
        vm.stopPrank();
        _assertSolvent("after partial liquidation");

        // Liquidation retired principal (no interest-only skim).
        (,, uint256 _principalAfter,,,,,,,) = gettersF.getLoanDetails(_loanId);
        assertLt(_principalAfter, _principalBefore, "principal retired by liquidation");

        _assertSolvent("final");
    }
}
