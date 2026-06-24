// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20Mock} from "@chainlink/contracts/src/v0.8/shared/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/shared/mocks/MockV3Aggregator.sol";

import "../../contracts/interfaces/IDiamondCut.sol";
import "../../contracts/facets/DiamondCutFacet.sol";
import "../../contracts/facets/DiamondLoupeFacet.sol";
import "../../contracts/facets/LiquidationFacet.sol";
import "../../contracts/facets/OwnershipFacet.sol";
import "../../contracts/facets/PriceOracleFacet.sol";
import "../../contracts/facets/ProtocolFacet.sol";
import "../../contracts/facets/PositionManagerFacet.sol";
import "../../contracts/facets/VaultManagerFacet.sol";
import "../../contracts/facets/YieldStrategyFacet.sol";
import "../../contracts/facets/GettersFacet.sol";
import "../../contracts/Diamond.sol";

import {Vm} from "forge-std/Vm.sol";

/// @title LendbitFuzz — Medusa stateful fuzzing harness for the Lendbit diamond.
/// @notice Deploys the full diamond + facets, three pranked actors, two ERC20
///         collateral tokens, the native collateral, and one funded borrow
///         vault. Handlers (the externally-callable, non-`property_` functions)
///         are the fuzz surface; `property_*` functions are the invariants
///         Medusa checks after every call.
contract LendbitFuzz is IDiamondCut {
    // Foundry-style cheatcode handle (Medusa implements this VM).
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ---- Diamond + facets (typed at the diamond address) ----
    Diamond diamond;
    ProtocolFacet protocolF;
    PositionManagerFacet positionManagerF;
    VaultManagerFacet vaultManagerF;
    PriceOracleFacet priceOracleF;
    LiquidationFacet liquidationF;
    YieldStrategyFacet yieldStrategyF;
    GettersFacet gettersF;

    // ---- Tokens / feeds ----
    ERC20Mock token1; // 18d collateral, ~$1500
    ERC20Mock token2; // 18d collateral, ~$300
    ERC20Mock borrowTok; // 18d borrowable (has a funded vault), ~$1
    address constant NATIVE = address(1);

    MockV3Aggregator feed1;
    MockV3Aggregator feed2;
    MockV3Aggregator feedBorrow;

    // current oracle answers (8 decimals), refreshed after every time warp
    int256 price1 = 1500e8;
    int256 price2 = 300e8;
    int256 priceBorrow = 1e8;

    // ---- Actors ----
    address[3] actors = [address(0xA11CE), address(0xB0B), address(0xCa101)];

    uint16 constant BASE_LTV = 8000;
    uint256 constant MAX_AMT = 1e24;

    constructor() {
        // ---- deploy facets ----
        DiamondCutFacet dCutFacet = new DiamondCutFacet();
        diamond = new Diamond(address(this), address(dCutFacet));
        DiamondLoupeFacet dLoupe = new DiamondLoupeFacet();
        OwnershipFacet ownerF = new OwnershipFacet();
        protocolF = new ProtocolFacet();
        positionManagerF = new PositionManagerFacet();
        vaultManagerF = new VaultManagerFacet();
        priceOracleF = new PriceOracleFacet();
        liquidationF = new LiquidationFacet();
        yieldStrategyF = new YieldStrategyFacet();
        gettersF = new GettersFacet();

        FacetCut[] memory cut = new FacetCut[](9);
        cut[0] = FacetCut(address(dLoupe), FacetCutAction.Add, generateSelectors("DiamondLoupeFacet"));
        cut[1] = FacetCut(address(ownerF), FacetCutAction.Add, generateSelectors("OwnershipFacet"));
        cut[2] = FacetCut(address(protocolF), FacetCutAction.Add, generateSelectors("ProtocolFacet"));
        cut[3] = FacetCut(address(positionManagerF), FacetCutAction.Add, generateSelectors("PositionManagerFacet"));
        cut[4] = FacetCut(address(vaultManagerF), FacetCutAction.Add, generateSelectors("VaultManagerFacet"));
        cut[5] = FacetCut(address(priceOracleF), FacetCutAction.Add, generateSelectors("PriceOracleFacet"));
        cut[6] = FacetCut(address(liquidationF), FacetCutAction.Add, generateSelectors("LiquidationFacet"));
        cut[7] = FacetCut(address(yieldStrategyF), FacetCutAction.Add, generateSelectors("YieldStrategyFacet"));
        cut[8] = FacetCut(address(gettersF), FacetCutAction.Add, generateSelectors("GettersFacet"));

        IDiamondCut(address(diamond)).diamondCut(cut, address(0x0), "");

        // retarget typed facets at the diamond
        protocolF = ProtocolFacet(address(diamond));
        positionManagerF = PositionManagerFacet(address(diamond));
        vaultManagerF = VaultManagerFacet(address(diamond));
        priceOracleF = PriceOracleFacet(address(diamond));
        liquidationF = LiquidationFacet(address(diamond));
        yieldStrategyF = YieldStrategyFacet(address(diamond));
        gettersF = GettersFacet(address(diamond));

        // ---- tokens + feeds ----
        token1 = new ERC20Mock(18);
        token2 = new ERC20Mock(18);
        borrowTok = new ERC20Mock(18);
        feed1 = new MockV3Aggregator(8, price1);
        feed2 = new MockV3Aggregator(8, price2);
        feedBorrow = new MockV3Aggregator(8, priceBorrow);

        // ---- whitelist + collateral config + interest ----
        positionManagerF.whitelistAddress(address(this));
        for (uint256 i; i < actors.length; ++i) {
            positionManagerF.whitelistAddress(actors[i]);
        }
        protocolF.addCollateralToken(address(token1), address(feed1), BASE_LTV);
        protocolF.addCollateralToken(address(token2), address(feed2), BASE_LTV);
        protocolF.addCollateralToken(NATIVE, address(feed1), BASE_LTV);
        protocolF.setInterestRate(2000, 500);

        // ---- borrow vault, funded with deep liquidity from the harness ----
        VaultConfiguration memory cfg = VaultConfiguration({
            totalDeposits: 0,
            totalBorrows: 0,
            baseRate: 2000,
            slopeRate: 3000,
            reserveFactor: 2000,
            optimalUtilization: 8000,
            liquidationBonus: 500,
            lastUpdated: block.timestamp
        });
        vaultManagerF.deployVault(address(borrowTok), address(feedBorrow), "xBorrow", "xBRW", cfg);
        uint256 seed = 1_000_000e18;
        borrowTok.mint(address(this), seed);
        borrowTok.approve(address(diamond), seed);
        vaultManagerF.deposit(address(borrowTok), seed);
    }

    // =====================================================================
    //                              Handlers
    // =====================================================================

    function depositCollateral(uint256 actorSeed, uint256 tokenSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, MAX_AMT);
        uint256 sel = tokenSeed % 3;
        if (sel == 2) {
            vm.deal(actor, amount);
            vm.prank(actor);
            protocolF.depositCollateral{value: amount}(NATIVE, amount);
        } else {
            ERC20Mock t = sel == 0 ? token1 : token2;
            t.mint(actor, amount);
            vm.prank(actor);
            t.approve(address(diamond), amount);
            vm.prank(actor);
            protocolF.depositCollateral(address(t), amount);
        }
    }

    function withdrawCollateral(uint256 actorSeed, uint256 tokenSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        address t = _collat(tokenSeed);
        uint256 posId = positionManagerF.getPositionIdForUser(actor);
        if (posId == 0) return;
        uint256 bal = gettersF.getPositionCollateral(posId, t);
        if (bal == 0) return;
        amount = _bound(amount, 1, bal);
        vm.prank(actor);
        protocolF.withdrawCollateral(t, amount);
    }

    function borrow(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, MAX_AMT);
        vm.prank(actor);
        protocolF.borrow(address(borrowTok), amount);
    }

    function repay(uint256 actorSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        amount = _bound(amount, 1, MAX_AMT);
        // fund the actor so the pull-transfer can succeed
        borrowTok.mint(actor, amount);
        vm.prank(actor);
        borrowTok.approve(address(diamond), amount);
        vm.prank(actor);
        protocolF.repay(address(borrowTok), amount);
    }

    function takeLoan(uint256 actorSeed, uint256 principal, uint256 tenure) public {
        address actor = _actor(actorSeed);
        principal = _bound(principal, 1, MAX_AMT);
        tenure = _bound(tenure, 1 days, 365 days);
        vm.prank(actor);
        protocolF.takeLoan(address(borrowTok), principal, tenure);
    }

    function repayLoan(uint256 actorSeed, uint256 loanSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 posId = positionManagerF.getPositionIdForUser(actor);
        if (posId == 0) return;
        uint256[] memory loans = gettersF.getUserActiveLoanIds(posId);
        if (loans.length == 0) return;
        uint256 loanId = loans[loanSeed % loans.length];
        amount = _bound(amount, 1, MAX_AMT);
        borrowTok.mint(actor, amount);
        vm.prank(actor);
        borrowTok.approve(address(diamond), amount);
        vm.prank(actor);
        protocolF.repayLoan(loanId, amount);
    }

    function liquidateLoan(uint256 actorSeed, uint256 loanSeed, uint256 collatSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256[] memory loans = gettersF.getActiveLoanIds();
        if (loans.length == 0) return;
        uint256 loanId = loans[loanSeed % loans.length];
        amount = _bound(amount, 1, MAX_AMT);
        borrowTok.mint(actor, amount);
        vm.prank(actor);
        borrowTok.approve(address(diamond), amount);
        vm.prank(actor);
        liquidationF.liquidateLoan(loanId, amount, _collat(collatSeed));
    }

    /// @notice Move a collateral price within a wide band to drive liquidations.
    function setCollateralPrice(uint256 tokenSeed, uint256 newPrice) public {
        uint256 sel = tokenSeed % 2;
        int256 p = int256(_bound(newPrice, 1e8, 5000e8));
        if (sel == 0) {
            price1 = p;
            feed1.updateAnswer(p);
        } else {
            price2 = p;
            feed2.updateAnswer(p);
        }
    }

    /// @notice Advance time (accrues interest / penalties), then refresh feeds
    ///         so the staleness guard keeps passing.
    function warp(uint256 delay) public {
        delay = _bound(delay, 1 hours, 30 days);
        vm.warp(block.timestamp + delay);
        feed1.updateAnswer(price1);
        feed2.updateAnswer(price2);
        feedBorrow.updateAnswer(priceBorrow);
    }

    // =====================================================================
    //                            Invariants
    // =====================================================================

    /// @dev The diamond must custody at least the token1 collateral it records.
    function property_collateral_solvency_token1() public view returns (bool) {
        return token1.balanceOf(address(diamond)) >= _sumCollateral(address(token1));
    }

    function property_collateral_solvency_token2() public view returns (bool) {
        return token2.balanceOf(address(diamond)) >= _sumCollateral(address(token2));
    }

    function property_native_collateral_solvency() public view returns (bool) {
        return address(diamond).balance >= _sumCollateral(NATIVE);
    }

    /// @dev Every minted position id maps to a real owner, and that owner maps
    ///      back to the same id.
    function property_position_owner_consistency() public view returns (bool) {
        uint256 next = positionManagerF.getNextPositionId();
        for (uint256 id = 1; id < next; ++id) {
            address owner = positionManagerF.getUserForPositionId(id);
            if (owner == address(0)) return false;
            if (positionManagerF.getPositionIdForUser(owner) != id) return false;
        }
        return true;
    }

    // =====================================================================
    //                             Helpers
    // =====================================================================

    function _sumCollateral(address token) internal view returns (uint256 total) {
        uint256 next = positionManagerF.getNextPositionId();
        for (uint256 id = 1; id < next; ++id) {
            total += gettersF.getPositionCollateral(id, token);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _collat(uint256 seed) internal view returns (address) {
        uint256 s = seed % 3;
        if (s == 0) return address(token1);
        if (s == 1) return address(token2);
        return NATIVE;
    }

    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (lo > hi) return lo;
        return lo + (x % (hi - lo + 1));
    }

    // ---- FFI selector generation (matches the existing Foundry tests) ----
    function generateSelectors(string memory _facetName) internal returns (bytes4[] memory selectors) {
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "scripts/genSelectors.js";
        cmd[2] = _facetName;
        bytes memory res = vm.ffi(cmd);
        selectors = abi.decode(res, (bytes4[]));
    }

    // IDiamondCut shim so the harness satisfies the interface like the tests do.
    function diamondCut(FacetCut[] calldata, address, bytes calldata) external override {}

    receive() external payable {}
}