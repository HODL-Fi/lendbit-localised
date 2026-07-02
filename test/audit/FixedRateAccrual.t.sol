// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";

/// @notice Finding #9 — the vault used to accrue ALL `totalBorrows` at the mutable
///         `interestRate`, while fixed loans repay at their immutable
///         `annualRateBps`. A governance rate hike then minted phantom interest on
///         fixed principal, inflating the ERC4626 share price so an early LP could
///         extract value the borrower will never pay. The fix accrues fixed
///         principal at its own snapshotted rate, so a rate change leaves the
///         fixed loan's LP accrual untouched.
contract FixedRateAccrualTest is Base {
    function test_fixedLoan_accrual_unaffected_by_rate_hike() public {
        createVaultAndFund(500e6);
        TokenVault vault = TokenVault(gettersF.getTokenVault(address(token4)));

        // Known starting rate: 20% APR (+ 5% penalty).
        protocolF.setInterestRate(2000, 500);

        // user1 opens a 200e6 fixed loan, snapshotting 20% as its immutable rate.
        uint256 _coll = 100_000e18;
        token2.mint(user1, _coll);
        vm.startPrank(user1);
        token2.approve(address(diamond), type(uint256).max);
        protocolF.depositCollateral(address(token2), _coll);
        uint256 _loanId = protocolF.takeLoan(address(token4), 200e6, 365 days);
        vm.stopPrank();

        uint256 _assetsAtHike = vault.totalAssets();
        uint256 _debtAtHike = gettersF.getOutstandingDebtForLoan(_loanId);

        // Governance TRIPLES the rate while the fixed loan is outstanding.
        protocolF.setInterestRate(6000, 500);

        // Accrue six months.
        vm.warp(block.timestamp + 365 days / 2);

        // Ground truth: the borrower still owes interest at the fixed 20%.
        uint256 _borrowerInterest = gettersF.getOutstandingDebtForLoan(_loanId) - _debtAtHike;
        uint256 _grossAt20 = (200e6 * 2000 * (365 days / 2)) / (10_000 * 365 days); // 20e6
        assertApproxEqAbs(_borrowerInterest, _grossAt20, 1e6, "borrower accrues at the fixed 20%, not 60%");

        // LP-visible accrual = the vault's totalAssets growth. It must track the
        // borrower's fixed-rate interest (net of the reserve factor), NEVER the
        // hiked 60% rate — that phantom is exactly the bug.
        uint256 _lpAccrual = vault.totalAssets() - _assetsAtHike;
        assertLe(_lpAccrual, _borrowerInterest, "LP accrual cannot exceed what the borrower owes at the fixed rate");
        assertGt(_lpAccrual, (_borrowerInterest * 8000) / 10_000, "LP still accrues the fixed-rate interest (net of reserve)");

        // Explicit phantom bound: had the fixed loan wrongly accrued at 60%, LP
        // value would have jumped by ~3x. Prove it is nowhere near that.
        uint256 _grossAt60 = (200e6 * 6000 * (365 days / 2)) / (10_000 * 365 days); // 60e6
        assertLt(_lpAccrual, _grossAt60, "no phantom interest at the hiked rate");
    }
}
