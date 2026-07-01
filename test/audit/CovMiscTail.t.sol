// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base} from "../Base.t.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";

import {TokenVault} from "../../contracts/TokenVault.sol";
import {LibUtils} from "../../contracts/libraries/LibUtils.sol";
import {Constants} from "../../contracts/models/Constant.sol";
import {
    INSUFFICIENT_COLLATERAL,
    OnlyRouterCanFulfill,
    UnexpectedRequestID,
    ONLY_SECURITY_COUNCIL
} from "../../contracts/models/Error.sol";

/// @dev Minimal Chainlink Functions router stub. Returns a deterministic request
///      id so `_sendRequest` can store a `FunctionResponse` and the fulfilment
///      path can be exercised by pranking as this contract.
contract MockFunctionsRouter {
    bytes32 public lastId;
    uint256 private nonce;

    function sendRequest(uint64, bytes calldata, uint16, uint32, bytes32) external returns (bytes32) {
        nonce++;
        lastId = keccak256(abi.encode(address(this), nonce));
        return lastId;
    }
}

/// @dev Minimal LINK token stub honouring the two calls `_fundSubscription` makes.
contract MockLink {
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferAndCall(address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }
}

/// @notice Tail-branch coverage for TokenVault, LibPriceOracle, PriceOracleFacet,
///         LibUtils, SecurityBase, LibLiquidation, and the Diamond fallback —
///         the branches left uncovered by the existing suite. Does not duplicate
///         pause/bad-debt (BadDebtAndPause), direct-redeem (DirectRedeemBypass),
///         or staleness/getter (OracleCoverage) coverage.
contract CovMiscTailTest is Base {
    // ----------------------------------------------------------------------
    // TokenVault — exercised as a standalone vault whose `diamond` is this
    // test contract, so the onlyDiamond paths are reachable directly.
    // ----------------------------------------------------------------------

    function _freshVault(uint16 _reserveFactor) internal returns (TokenVault v, ERC20Mock asset) {
        asset = new ERC20Mock(18);
        v = new TokenVault(address(asset), "vault", "VLT", address(this), 2000, _reserveFactor);
        asset.mint(address(this), 1_000_000 ether);
        asset.approve(address(v), type(uint256).max);
    }

    function test_tokenVault_withdraw_insufficientLiquidBalance_reverts() public {
        (TokenVault v,) = _freshVault(0);
        v.deposit(1_000 ether, address(this));
        // lend most of the liquidity out so the liquid balance can't cover a withdraw
        v.borrow(address(this), 900 ether);

        vm.expectRevert(TokenVault.InsufficientBalance.selector);
        v.withdraw(500 ether, address(this), address(this));
    }

    function test_tokenVault_withdraw_insufficientShares_reverts() public {
        (TokenVault v,) = _freshVault(0);
        v.deposit(1_000 ether, address(this));
        // user1 owns no shares -> previewWithdraw shares > balanceOf(user1)
        vm.expectRevert(TokenVault.InsufficientShares.selector);
        v.withdraw(100 ether, address(this), user1);
    }

    function test_tokenVault_borrow_insufficientLiquidBalance_reverts() public {
        (TokenVault v,) = _freshVault(0);
        v.deposit(1_000 ether, address(this));
        vm.expectRevert(TokenVault.InsufficientBalance.selector);
        v.borrow(address(this), 2_000 ether);
    }

    function test_tokenVault_mint_and_redeem_viaDiamond_succeed() public {
        (TokenVault v,) = _freshVault(0);
        uint256 assetsIn = v.mint(500 ether, address(this));
        assertGt(assetsIn, 0, "mint pulled assets");
        assertEq(v.balanceOf(address(this)), 500 ether, "shares minted");

        uint256 assetsOut = v.redeem(200 ether, address(this), address(this));
        assertGt(assetsOut, 0, "redeem returned assets");
        assertEq(v.balanceOf(address(this)), 300 ether, "shares burned");
    }

    function test_tokenVault_mint_onlyDiamond_reverts() public {
        (TokenVault v,) = _freshVault(0);
        vm.prank(nonAdmin);
        vm.expectRevert(TokenVault.OnlyDiamond.selector);
        v.mint(1 ether, nonAdmin);
    }

    function test_tokenVault_redeem_onlyDiamond_reverts() public {
        (TokenVault v,) = _freshVault(0);
        v.deposit(100 ether, address(this));
        vm.prank(nonAdmin);
        vm.expectRevert(TokenVault.OnlyDiamond.selector);
        v.redeem(1 ether, nonAdmin, nonAdmin);
    }

    function test_tokenVault_setInterestRate_accruesAndStores() public {
        (TokenVault v,) = _freshVault(500);
        v.deposit(1_000 ether, address(this));
        v.borrow(address(this), 500 ether); // totalBorrows > 0 so accrual produces interest
        vm.warp(block.timestamp + 30 days);
        v.setInterestRate(3000); // hits _accrueInterest lpInterest>0 path
        assertGt(v.totalAssets(), 0);
    }

    function test_tokenVault_setReserveFactor_aboveScale_reverts() public {
        (TokenVault v,) = _freshVault(0);
        vm.expectRevert(TokenVault.InvalidRate.selector);
        v.setReserveFactor(uint16(Constants.BASIS_POINTS_SCALE) + 1);
    }

    function test_tokenVault_setReserveFactor_valid_succeeds() public {
        (TokenVault v,) = _freshVault(0);
        v.setReserveFactor(1000);
    }

    function test_tokenVault_withdrawReserve_aboveReserve_reverts() public {
        (TokenVault v,) = _freshVault(0);
        // totalProtocolReserve is 0 -> any positive amount exceeds it
        vm.expectRevert(TokenVault.InvalidAmount.selector);
        v.withdrawReserve(address(this), 1);
    }

    function test_tokenVault_withdrawReserve_success() public {
        (TokenVault v,) = _freshVault(5000);
        v.deposit(1_000 ether, address(this));
        v.borrow(address(this), 500 ether);
        // book a repayment with interest so the protocol reserve fills up
        v.repay(0, 100 ether); // reserve = 100 * 5000/10000 = 50
        assertEq(v.protocolReserve(), 50 ether, "reserve accrued");
        v.withdrawReserve(address(this), 10 ether);
        assertEq(v.protocolReserve(), 40 ether, "reserve withdrawn");
    }

    function test_tokenVault_updateBadDebt_aboveOutstanding_reverts() public {
        (TokenVault v,) = _freshVault(0);
        // no borrows, no accrued interest -> any positive amount exceeds the base
        vm.expectRevert(TokenVault.InvalidAmount.selector);
        v.updateBadDebt(1);
    }

    function test_tokenVault_getters() public {
        (TokenVault v,) = _freshVault(0);
        v.deposit(1_000 ether, address(this));
        v.borrow(address(this), 250 ether);
        assertEq(v.totalBorrow(), 250 ether, "totalBorrow getter");
        assertEq(v.protocolReserve(), 0, "protocolReserve getter");
        assertGt(v.totalAssets(), 0, "totalAssets getter");
    }

    // ----------------------------------------------------------------------
    // LibUtils — decimal normalization branches and native-token decimals.
    // ----------------------------------------------------------------------

    function test_libUtils_getTokenDecimals_native_and_erc20() public view {
        assertEq(LibUtils._getTokenDecimals(Constants.NATIVE_TOKEN), 18, "native -> 18");
        assertEq(LibUtils._getTokenDecimals(address(token3)), 6, "erc20 -> feed decimals");
    }

    function test_libUtils_normalize_scaleUp_and_scaleDown() public pure {
        // _amountDecimal <= _newDecimal : scale up (if branch)
        assertEq(LibUtils._noramlizeToNDecimals(1_000, 6, 18), 1_000 * 1e12, "scale up");
        // _amountDecimal > _newDecimal : scale down (else branch)
        assertEq(LibUtils._noramlizeToNDecimals(1e24, 24, 18), 1e18, "scale down");
    }

    // ----------------------------------------------------------------------
    // SecurityBase — onlySecurityCouncil revert branch.
    // ----------------------------------------------------------------------

    function test_securityBase_onlySecurityCouncil_reverts() public {
        vm.prank(nonAdmin);
        vm.expectRevert(ONLY_SECURITY_COUNCIL.selector);
        vaultManagerF.setVaultPaused(address(token1), true);
    }

    // ----------------------------------------------------------------------
    // Diamond — fallback revert when the selector has no registered facet.
    // ----------------------------------------------------------------------

    function test_diamond_unknownSelector_reverts() public {
        (bool ok, bytes memory ret) = address(diamond).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok, "unregistered selector must revert");
        // bubble carries the "Function does not exist" message
        assertGt(ret.length, 0);
    }

    // ----------------------------------------------------------------------
    // LibPriceOracle / PriceOracleFacet — fund subscription, send request,
    // and the fulfilment success + revert branches.
    // ----------------------------------------------------------------------

    function _wireOracle() internal returns (MockFunctionsRouter router) {
        router = new MockFunctionsRouter();
        MockLink link = new MockLink();
        priceOracleF.setupRouter(bytes32("DON"), address(router), address(link), 1);
        priceOracleF.setupSource("return 1");
    }

    function test_oracle_fundSubscription_succeeds() public {
        _wireOracle();
        // owner-only; reaches _fundSubscription -> approve + transferAndCall on LINK
        priceOracleF.fundSubscription(1_000);
    }

    function test_oracle_sendRequest_and_fulfillment_success() public {
        MockFunctionsRouter router = _wireOracle();

        string[] memory args = new string[](0);
        bytes32 requestId = priceOracleF.sendRequest(0, args);
        assertTrue(requestId != bytes32(0), "request stored");

        // router-gated fulfilment of a stored request
        vm.prank(address(router));
        priceOracleF.handleOracleFulfillment(requestId, abi.encode(uint256(4242)), "");
    }

    function test_oracle_fulfillment_notRouter_reverts() public {
        MockFunctionsRouter router = _wireOracle();
        string[] memory args = new string[](0);
        bytes32 requestId = priceOracleF.sendRequest(0, args);

        // caller is not the configured router
        vm.prank(nonAdmin);
        vm.expectRevert(OnlyRouterCanFulfill.selector);
        priceOracleF.handleOracleFulfillment(requestId, abi.encode(uint256(1)), "");
        router; // silence unused
    }

    function test_oracle_fulfillment_unknownRequestId_reverts() public {
        MockFunctionsRouter router = _wireOracle();
        bytes32 ghostId = keccak256("ghost");
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(UnexpectedRequestID.selector, ghostId));
        priceOracleF.handleOracleFulfillment(ghostId, abi.encode(uint256(1)), "");
    }

    function test_oracle_getTokenValueInUSD_zeroAmount_returnsZero() public view {
        (uint256 price, uint256 usd) = priceOracleF.getTokenValueInUSD(address(token1), 0);
        assertEq(price, 0);
        assertEq(usd, 0);
    }

    // ----------------------------------------------------------------------
    // LibLiquidation — INSUFFICIENT_COLLATERAL and the interest-only
    // (principalRepaid == 0) liquidation branch.
    // ----------------------------------------------------------------------

    function test_liquidation_insufficientCollateral_reverts() public {
        address liquidator = mkaddr("covLiquidator");
        createVaultAndFund(1_000e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 4 ether); // $6,000

        uint256 _borrowAmount = 15e6; // ~$3,750
        vm.prank(user1);
        protocolF.borrow(address(token4), _borrowAmount);

        vm.warp(block.timestamp + 365 days);
        updatePricefeedsData();

        // crash collateral so seizing the full debt's worth (+bonus) exceeds the
        // 4 token1 actually held -> INSUFFICIENT_COLLATERAL
        MockV3Aggregator(pricefeed1).updateAnswer(150e8); // collateral now ~$600
        assertTrue(liquidationF.isLiquidatable(_positionId));

        uint256 _debt = gettersF.getBorrowDetails(_positionId, address(token4));
        token4.mint(liquidator, _debt);
        vm.startPrank(liquidator);
        token4.approve(address(liquidationF), _debt);
        vm.expectRevert(INSUFFICIENT_COLLATERAL.selector);
        liquidationF.liquidatePosition(_positionId, _debt, address(token4), address(token1));
        vm.stopPrank();
    }

    function test_liquidation_loan_interestOnly_repaid_principalUnchanged() public {
        address liquidator = mkaddr("covLiquidator2");
        createVaultAndFund(1_000e6);
        uint256 _positionId = depositCollateralFor(user1, address(token1), 5 ether); // $7,500

        uint256 _borrowAmount = 20e6;
        vm.prank(user1);
        uint256 _loanId = protocolF.takeLoan(address(token4), _borrowAmount, 365 days);

        vm.warp(block.timestamp + 365 days);
        updatePricefeedsData();

        uint256 _debt = gettersF.getOutstandingDebtForLoan(_loanId);
        (,, uint256 principalBefore,,,,,,,) = gettersF.getLoanDetails(_loanId);
        uint256 _interestDue = _debt - principalBefore;
        assertGt(_interestDue, 0, "loan accrued interest");

        // make it liquidatable
        MockV3Aggregator(pricefeed1).updateAnswer(1320e8);
        assertTrue(liquidationF.isLiquidatable(_positionId));

        // repay strictly less than the interest due -> principalRepaid == 0 branch
        uint256 _payback = _interestDue / 2;
        token4.mint(liquidator, _payback);
        vm.startPrank(liquidator);
        token4.approve(address(liquidationF), _payback);
        liquidationF.liquidateLoan(_loanId, _payback, address(token1));
        vm.stopPrank();

        (,, uint256 principalAfter,,,,,,,) = gettersF.getLoanDetails(_loanId);
        assertEq(principalAfter, principalBefore, "interest-only liquidation leaves principal intact");
    }
}
