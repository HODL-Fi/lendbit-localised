// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {TokenVault} from "../../contracts/TokenVault.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

/// @notice Demonstrates the deployed fixed-rate economics now that pooled
///         borrower debt and vault LP accrual share one rate (#11). The APR is
///         grossed up to 27.78% so that, despite `MAX_UTILIZATION` capping the
///         pool at 90%, LPs still realize ~20% on their deposited capital at the
///         utilization ceiling; the protocol reserve takes ~5%. Below the cap LP
///         yield scales down with utilization ("current utilization").
contract FixedRateLpSplitTest is Base {
    address lp = makeAddr("lp");
    address borrower = makeAddr("borrower");

    uint16 constant APR = 2778;      // 27.78% — grossed up by 1/0.9 for the 90% cap
    uint16 constant RESERVE = 2000;  // 20% reserveFactor (deployed value)
    uint256 constant DEPOSIT = 1_000e6;

    function _config() internal {
        createVaultAndFund(0); // deploy token4 vault (6 decimals), no initial fund
        protocolF.setInterestRate(APR, 500);                       // pushes APR to the vault
        vaultManagerF.setReserveFactor(address(token4), RESERVE);  // pushes reserve to the vault
        positionManagerF.whitelistAddress(borrower);
        positionManagerF.whitelistAddress(lp);
    }

    function _lpDeposit(uint256 amt) internal {
        token4.mint(lp, amt);
        vm.startPrank(lp);
        token4.approve(address(diamond), amt);
        vaultManagerF.deposit(address(token4), amt);
        vm.stopPrank();
    }

    function _borrow(uint256 amt) internal returns (uint256 posId) {
        posId = depositCollateralFor(borrower, address(token1), 1_000_000 ether); // ample collateral
        vm.prank(borrower);
        protocolF.borrow(address(token4), amt);
    }

    function _yearPasses() internal {
        vm.warp(block.timestamp + 365 days);
        MockV3Aggregator(pricefeed1).updateAnswer(1500e8); // refresh feeds
        MockV3Aggregator(pricefeed4).updateAnswer(250e8);
    }

    function _repayInFull(uint256 posId) internal {
        uint256 debt = gettersF.getBorrowDetails(posId, address(token4));
        token4.mint(borrower, debt);
        vm.startPrank(borrower);
        token4.approve(address(diamond), debt);
        protocolF.repay(address(token4), debt);
        vm.stopPrank();
    }

    function _lpClaim() internal view returns (uint256) {
        TokenVault vault = TokenVault(gettersF.getTokenVault(address(token4)));
        return vault.convertToAssets(vault.balanceOf(lp));
    }

    /// @dev Near-cap (89%) utilization for a year: LP realizes ~20% on deposit.
    ///      At the strict-< 90% ceiling LP -> 20.0%; this 89% sample lands ~19.78%.
    function test_grossed_up_apr_gives_lp_20pct_at_cap() public {
        _config();
        _lpDeposit(DEPOSIT);

        uint256 posId = _borrow((DEPOSIT * 8900) / 10000); // 890e6, 89% util (under the 90% cap)
        _yearPasses();

        // borrower owes principal + 27.78% on the borrowed amount
        assertEq(gettersF.getBorrowDetails(posId, address(token4)), 1_137_242_000, "principal + fixed 27.78%");
        _repayInFull(posId);

        // protocol ~5% on deposit; LP ~20% on deposit (the idle ~11% earns nothing)
        assertApproxEqAbs(vaultManagerF.getVaultReserve(address(token4)), 49_448_400, 1e6, "protocol ~5% at 89% util");
        assertApproxEqAbs(_lpClaim(), 1_197_793_600, 1e6, "LP realizes ~20% on deposit at the utilization cap");
    }

    /// @dev 50% utilization: LP yield scales down with utilization (~11.1%).
    function test_below_cap_lp_yield_scales_with_utilization() public {
        _config();
        _lpDeposit(DEPOSIT);

        uint256 posId = _borrow(DEPOSIT / 2); // 50% util
        _yearPasses();
        _repayInFull(posId);

        // 27.78% on half the pool -> ~138.9e6 interest; LP slice (80%) ~111.1e6 = ~11.1% of deposit
        assertApproxEqAbs(_lpClaim(), 1_111_120_000, 1e6, "LP yield ~11.1% at 50% util (tracks utilization)");
        assertApproxEqAbs(vaultManagerF.getVaultReserve(address(token4)), 27_780_000, 1e6, "protocol ~2.8% at 50% util");
    }
}
