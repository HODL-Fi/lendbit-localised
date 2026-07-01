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
import {TokenVault} from "../../contracts/TokenVault.sol";
import {MockAavePool} from "../../contracts/mocks/MockAavePool.sol";

import {Vm} from "forge-std/Vm.sol";

/// @title LendbitFuzz — Medusa stateful fuzzing harness for the Lendbit diamond.
/// @notice Deploys the full diamond + facets, three pranked actors, collateral
///         (token1, token2, native, and the dual token), and two funded borrow
///         vaults — one of whose tokens (`dualTok`) is also registered as
///         collateral. Handlers (the externally-callable, non-`property_`
///         functions) are the fuzz surface; `property_*` functions are the
///         invariants Medusa checks after every call.
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
    address constant NATIVE = address(1);

    MockV3Aggregator feed1;
    MockV3Aggregator feed2;

    // ---- Two borrowable tokens with DIFFERENT decimals, each with its own
    //      funded vault. Exercises the protocol's decimal-normalization math. ----
    ERC20Mock[2] borrowToks;
    MockV3Aggregator[2] borrowFeeds;
    TokenVault[2] borrowVaults;
    uint8[2] borrowDecimals = [6, 2]; // token A: 6d (~$1), token B: 2d (~$2)
    int256[2] borrowPrices = [int256(1e8), int256(2e8)];
    uint256[2] borrowSeeds; // 1,000,000 whole tokens per vault, in raw units (set in ctor)

    // borrowToks[0] is ALSO registered as collateral — one token that is both
    // deposited as collateral (held in the diamond) and borrowable (liquidity in
    // its vault). The two balances live at distinct addresses and never commingle.
    ERC20Mock dualTok;

    // Net LP principal in each vault (deposits − withdrawals), floored at 0. The
    // harness is the sole LP; this generalizes the fixed seed floor once LPs can
    // withdraw, and is the lower bound the vault must always remain able to back.
    uint256[2] ghost_vaultNet;

    // Origination rate recorded per takeLoan() loan, to prove a fixed-term loan
    // keeps its rate even after governance changes the global rate.
    mapping(uint256 => uint16) ghost_loanAnnual;
    mapping(uint256 => uint16) ghost_loanPenalty;
    mapping(uint256 => bool) ghost_loanSeen;

    // ---- Yield strategy (Aave mock) for the two ERC20 collaterals ----
    MockAavePool aavePool1;
    MockAavePool aavePool2;
    ERC20Mock aToken1;
    ERC20Mock aToken2;

    // current collateral oracle answers (8 decimals), refreshed after every time warp
    int256 price1 = 1500e8;
    int256 price2 = 300e8;

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
        feed1 = new MockV3Aggregator(8, price1);
        feed2 = new MockV3Aggregator(8, price2);
        for (uint256 i; i < borrowToks.length; ++i) {
            borrowToks[i] = new ERC20Mock(borrowDecimals[i]);
            borrowFeeds[i] = new MockV3Aggregator(8, borrowPrices[i]);
            borrowSeeds[i] = 1_000_000 * (10 ** borrowDecimals[i]);
        }

        // ---- whitelist + collateral config + interest ----
        positionManagerF.whitelistAddress(address(this));
        for (uint256 i; i < actors.length; ++i) {
            positionManagerF.whitelistAddress(actors[i]);
        }
        protocolF.addCollateralToken(address(token1), address(feed1), BASE_LTV);
        protocolF.addCollateralToken(address(token2), address(feed2), BASE_LTV);
        protocolF.addCollateralToken(NATIVE, address(feed1), BASE_LTV);
        // dual token: borrowToks[0] is collateral AND borrowable
        dualTok = borrowToks[0];
        protocolF.addCollateralToken(address(dualTok), address(borrowFeeds[0]), BASE_LTV);
        protocolF.setInterestRate(2000, 500);

        // Disable oracle staleness so price-reading paths (and invariants) never
        // revert just because Medusa advanced block.timestamp between calls.
        priceOracleF.setPriceFeedStalenessThreshold(address(token1), type(uint32).max);
        priceOracleF.setPriceFeedStalenessThreshold(address(token2), type(uint32).max);
        priceOracleF.setPriceFeedStalenessThreshold(NATIVE, type(uint32).max);
        for (uint256 i; i < borrowToks.length; ++i) {
            priceOracleF.setPriceFeedStalenessThreshold(address(borrowToks[i]), type(uint32).max);
        }

        // Wire an Aave-style yield strategy for the two ERC20 collaterals so the
        // strategy path (supply / withdraw / accrue / claim) is part of the
        // fuzz surface. 50% allocation, 10% protocol share. Native cannot have a
        // strategy (the protocol rejects it).
        aavePool1 = new MockAavePool(address(token1), 18);
        aavePool2 = new MockAavePool(address(token2), 18);
        aToken1 = aavePool1.aToken();
        aToken2 = aavePool2.aToken();
        yieldStrategyF.configureYieldToken(address(token1), address(aavePool1), address(aToken1), 5000, 1000);
        yieldStrategyF.configureYieldToken(address(token2), address(aavePool2), address(aToken2), 5000, 1000);

        // ---- borrow vaults, each funded with deep liquidity from the harness ----
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
        for (uint256 i; i < borrowToks.length; ++i) {
            borrowVaults[i] = TokenVault(
                vaultManagerF.deployVault(address(borrowToks[i]), address(borrowFeeds[i]), "xBorrow", "xBRW", cfg)
            );
            borrowToks[i].mint(address(this), borrowSeeds[i]);
            borrowToks[i].approve(address(diamond), borrowSeeds[i]);
            vaultManagerF.deposit(address(borrowToks[i]), borrowSeeds[i]);
            ghost_vaultNet[i] = borrowSeeds[i];
        }
    }

    // =====================================================================
    //                              Handlers
    // =====================================================================

    function depositCollateral(uint256 actorSeed, uint256 tokenSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 sel = tokenSeed % 4;
        if (sel == 3) {
            amount = _bound(amount, 1, 1000 ether);
            vm.deal(actor, amount);
            vm.prank(actor);
            protocolF.depositCollateral{value: amount}(NATIVE, amount);
        } else {
            ERC20Mock t = sel == 0 ? token1 : sel == 1 ? token2 : dualTok;
            amount = _bound(amount, 1, 1_000_000 * (10 ** t.decimals())); // decimal-aware (dualTok is 6d)
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

    function borrow(uint256 actorSeed, uint256 borrowSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 i = borrowSeed % borrowToks.length;
        amount = _bound(amount, 1, borrowSeeds[i]); // bound by that vault's liquidity (raw units)
        vm.prank(actor);
        protocolF.borrow(address(borrowToks[i]), amount);
    }

    function repay(uint256 actorSeed, uint256 borrowSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 i = borrowSeed % borrowToks.length;
        amount = _bound(amount, 1, borrowSeeds[i]);
        // fund the actor so the pull-transfer can succeed
        _fundAndApprove(borrowToks[i], actor, amount);
        vm.prank(actor);
        protocolF.repay(address(borrowToks[i]), amount);
    }

    function takeLoan(uint256 actorSeed, uint256 borrowSeed, uint256 principal, uint256 tenure) public {
        address actor = _actor(actorSeed);
        uint256 i = borrowSeed % borrowToks.length;
        principal = _bound(principal, 1, borrowSeeds[i]);
        tenure = _bound(tenure, 1 days, 365 days);
        vm.prank(actor);
        uint256 loanId = protocolF.takeLoan(address(borrowToks[i]), principal, tenure);
        // snapshot the rate this loan was originated at
        (,,,,,,, uint16 annual, uint16 penalty,) = gettersF.getLoanDetails(loanId);
        ghost_loanAnnual[loanId] = annual;
        ghost_loanPenalty[loanId] = penalty;
        ghost_loanSeen[loanId] = true;
    }

    function repayLoan(uint256 actorSeed, uint256 loanSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256 posId = positionManagerF.getPositionIdForUser(actor);
        if (posId == 0) return;
        uint256[] memory loans = gettersF.getUserActiveLoanIds(posId);
        if (loans.length == 0) return;
        uint256 loanId = loans[loanSeed % loans.length];
        // fund the actor in the loan's own token, bounded by its decimals
        (, address loanTok,,,,,,,,) = gettersF.getLoanDetails(loanId);
        amount = _bound(amount, 1, _capForToken(loanTok));
        _fundAndApprove(ERC20Mock(loanTok), actor, amount);
        vm.prank(actor);
        protocolF.repayLoan(loanId, amount);
    }

    /// @notice Governance changes the global interest/penalty rate. New loans
    ///         pick this up at origination; existing loans must not.
    /// @dev Full uint16 range — `annual + penalty` can exceed 65535. Before the
    ///      uint256-cast fix in `_outstandingBalance` this overflowed and bricked
    ///      overdue loans (see test/audit/FixedRateOverflow.t.sol); the fuzzer
    ///      now exercises that range to confirm the fix holds.
    function changeInterestRate(uint256 newRate, uint256 newPenalty) public {
        uint16 r = uint16(_bound(newRate, 1, type(uint16).max));
        uint16 p = uint16(_bound(newPenalty, 1, type(uint16).max));
        protocolF.setInterestRate(r, p); // harness = security council
    }

    /// @notice Behavioral fixed-rate check: an existing loan's outstanding debt
    ///         is read, the global rate is changed (no time passes), and the
    ///         debt is re-read. They MUST be equal — a fixed-term loan accrues at
    ///         its origination rate, never the current global rate. A divergence
    ///         would mean the repayment math leaks the live global rate into an
    ///         already-open loan.
    function checkLoanRateInvariance(uint256 loanSeed, uint256 newRate, uint256 newPenalty) public {
        uint256[] memory loans = gettersF.getActiveLoanIds();
        if (loans.length == 0) return;
        uint256 loanId = loans[loanSeed % loans.length];
        uint256 debtBefore = gettersF.getOutstandingDebtForLoan(loanId);
        uint16 r = uint16(_bound(newRate, 1, type(uint16).max));
        uint16 p = uint16(_bound(newPenalty, 1, type(uint16).max));
        protocolF.setInterestRate(r, p);
        uint256 debtAfter = gettersF.getOutstandingDebtForLoan(loanId);
        assert(debtAfter == debtBefore);
    }

    function liquidateLoan(uint256 actorSeed, uint256 loanSeed, uint256 collatSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        uint256[] memory loans = gettersF.getActiveLoanIds();
        if (loans.length == 0) return;
        uint256 loanId = loans[loanSeed % loans.length];
        // the liquidator repays in the loan's own token, bounded by its decimals
        (, address loanTok,,,,,,,,) = gettersF.getLoanDetails(loanId);
        amount = _bound(amount, 1, _capForToken(loanTok));
        _fundAndApprove(ERC20Mock(loanTok), actor, amount);
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
        for (uint256 i; i < borrowFeeds.length; ++i) {
            borrowFeeds[i].updateAnswer(borrowPrices[i]);
        }
    }

    /// @notice Move a position's collateral toward its target Aave allocation.
    function rebalanceYield(uint256 actorSeed, uint256 tokenSeed) public {
        address actor = _actor(actorSeed);
        address t = tokenSeed % 2 == 0 ? address(token1) : address(token2);
        vm.prank(actor);
        yieldStrategyF.rebalanceMyPosition(t);
    }

    /// @notice Accrue external Aave yield (mints aTokens to the diamond and
    ///         underlying to the pool), feeding the accrue/claim path.
    function simulateAaveYield(uint256 tokenSeed, uint256 amount) public {
        amount = _bound(amount, 1, 1e21);
        MockAavePool pool = tokenSeed % 2 == 0 ? aavePool1 : aavePool2;
        pool.simulateYield(address(diamond), amount);
    }

    /// @notice A position owner claims their accrued yield.
    function claimYield(uint256 actorSeed, uint256 tokenSeed, uint256 amount) public {
        address actor = _actor(actorSeed);
        address t = tokenSeed % 2 == 0 ? address(token1) : address(token2);
        amount = _bound(amount, 1, 1e21);
        vm.prank(actor);
        yieldStrategyF.claimYield(t, amount, actor);
    }

    /// @notice Security council harvests the protocol's yield share.
    function harvestProtocolYield(uint256 tokenSeed, uint256 amount) public {
        address t = tokenSeed % 2 == 0 ? address(token1) : address(token2);
        amount = _bound(amount, 1, 1e21);
        yieldStrategyF.harvestProtocolYield(t, address(this), amount);
    }

    /// @notice LP (the harness) adds liquidity to a borrow vault.
    function vaultDeposit(uint256 borrowSeed, uint256 amount) public {
        uint256 i = borrowSeed % borrowToks.length;
        amount = _bound(amount, 1, borrowSeeds[i]);
        borrowToks[i].mint(address(this), amount);
        borrowToks[i].approve(address(diamond), amount);
        vaultManagerF.deposit(address(borrowToks[i]), amount);
        ghost_vaultNet[i] += amount;
    }

    /// @notice LP (the harness) withdraws liquidity. The amount is intentionally
    ///         NOT clamped to available liquidity: the fuzzer probes
    ///         over-withdrawal, and the vault must revert (InsufficientBalance)
    ///         rather than pay out borrowed-out funds. The ghost update runs only
    ///         if `withdraw` succeeded — a revert rolls the whole call back.
    function vaultWithdraw(uint256 borrowSeed, uint256 amount) public {
        uint256 i = borrowSeed % borrowToks.length;
        amount = _bound(amount, 1, 2 * borrowSeeds[i]);
        vaultManagerF.withdraw(address(borrowToks[i]), amount);
        ghost_vaultNet[i] = amount >= ghost_vaultNet[i] ? 0 : ghost_vaultNet[i] - amount;
    }

    // =====================================================================
    //                            Invariants
    // =====================================================================

    /// @dev The diamond must back at least the collateral it records — counting
    ///      both what sits idle in the diamond and what the yield strategy holds
    ///      as aTokens (collateral allocated to Aave leaves as underlying and
    ///      returns as aTokens 1:1; accrued yield only adds to the aToken side).
    function property_collateral_solvency_token1() public view returns (bool) {
        uint256 held = token1.balanceOf(address(diamond)) + aToken1.balanceOf(address(diamond));
        return held >= _sumCollateral(address(token1));
    }

    function property_collateral_solvency_token2() public view returns (bool) {
        uint256 held = token2.balanceOf(address(diamond)) + aToken2.balanceOf(address(diamond));
        return held >= _sumCollateral(address(token2));
    }

    function property_native_collateral_solvency() public view returns (bool) {
        return address(diamond).balance >= _sumCollateral(NATIVE);
    }

    /// @dev The dual token is collateral AND borrowable. Its collateral sits in
    ///      the diamond; its borrow liquidity sits in its vault (a different
    ///      address). Borrowing/repaying never touches the diamond's balance of
    ///      it, so the diamond must still custody exactly the dual-token
    ///      collateral it records — even when an actor borrows the same token it
    ///      posted as collateral. (No yield strategy is wired for it.)
    function property_collateral_solvency_dual() public view returns (bool) {
        return dualTok.balanceOf(address(diamond)) >= _sumCollateral(address(dualTok));
    }

    /// @dev Vault solvency, per vault: liquid balance plus outstanding borrowed
    ///      principal must always cover net LP principal (deposits − withdrawals).
    ///      Every flow conserves this — `borrow` moves funds out while raising
    ///      `totalBorrow` by the same amount; `repay`/`liquidateLoan` transfer
    ///      the repaid asset back in before lowering `totalBorrow`; LP
    ///      deposit/withdraw move `liquid` and the ghost together. A drop below
    ///      the ghost means an LP pulled borrowed-out funds (or debt was cleared
    ///      without repayment) — exactly the "LPs can only withdraw available
    ///      liquidity, never the borrowed-out 2%" property. Interest only adds to
    ///      the asset side, so net principal is a safe, false-positive-free floor.
    function property_vault_solvency() public view returns (bool) {
        for (uint256 i; i < borrowVaults.length; ++i) {
            uint256 liquid = borrowToks[i].balanceOf(address(borrowVaults[i]));
            if (liquid + borrowVaults[i].totalBorrow() < ghost_vaultNet[i]) return false;
        }
        return true;
    }

    /// @dev No healthy position is liquidatable. A position with health factor
    ///      >= 1e18 has debt <= LTV-weighted collateral (80%), which is strictly
    ///      below the 90% liquidation threshold `isLiquidatable` uses — so the
    ///      two gates can never both fire. A violation means a solvent borrower
    ///      could be liquidated.
    function property_healthy_position_not_liquidatable() public view returns (bool) {
        uint256 next = positionManagerF.getNextPositionId();
        for (uint256 id = 1; id < next; ++id) {
            uint256 hf = gettersF.getHealthFactor(id, 0);
            if (hf >= 1e18 && liquidationF.isLiquidatable(id)) {
                return false;
            }
        }
        return true;
    }

    /// @dev Recorded borrower debt must cover each vault's outstanding principal,
    ///      checked PER TOKEN. `totalBorrow()` is pure principal (interest lives
    ///      in a separate bucket); each position's recorded debt for a token is
    ///      principal + accrued interest, so the per-token sum is always >= that
    ///      vault's principal. Bucketing by token matters once there is more than
    ///      one borrowable token: `getTotalActiveDebt` sums P2P loans across all
    ///      tokens in raw units, so the P2P leg is filtered by `loan.token` here
    ///      instead. A violation means a vault booked more lent-out principal
    ///      than borrowers actually owe in that token — the double-counting class
    ///      fixed in H-02.
    function property_recorded_debt_covers_vault_principal() public view returns (bool) {
        for (uint256 i; i < borrowVaults.length; ++i) {
            if (_recordedDebtForToken(address(borrowToks[i])) < borrowVaults[i].totalBorrow()) {
                return false;
            }
        }
        return true;
    }

    /// @dev A fixed-term loan's rate is immutable. The rate is snapshotted into
    ///      the loan at `takeLoan` and the contract must never rewrite it — not
    ///      when governance changes the global rate, not on repay/liquidate. For
    ///      every active loan, the on-chain stored rate still equals the value
    ///      recorded at origination.
    function property_loan_rate_immutable() public view returns (bool) {
        uint256[] memory loans = gettersF.getActiveLoanIds();
        for (uint256 k; k < loans.length; ++k) {
            uint256 loanId = loans[k];
            if (!ghost_loanSeen[loanId]) continue;
            (,,,,,,, uint16 annual, uint16 penalty,) = gettersF.getLoanDetails(loanId);
            if (annual != ghost_loanAnnual[loanId]) return false;
            if (penalty != ghost_loanPenalty[loanId]) return false;
        }
        return true;
    }

    /// NOTE: a `config.totalBorrows >= vault.totalBorrow()` invariant was tried
    /// here and REMOVED as vacuous. `TokenVault.repay` over-subtracts its own
    /// `totalBorrows` by the same interest band that `_repayStateChanges` /
    /// `_liquidateLoan` over-subtract from `config`, so both ledgers under-count
    /// together and the comparison never trips. Catching the under-count needs
    /// an independent true-principal ghost (borrow += amount, repay -=
    /// min(applied, trackedPrincipal)) — see test/audit/PooledBorrowTally.t.sol
    /// for the confirmed PoC. Not added to the live suite while the pooled +
    /// vault legs remain unfixed (it would gate the whole suite red).

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

    /// @dev Pooled debt for `token` (already per-token) plus this position's P2P
    ///      loans denominated in `token`, summed across every position.
    function _recordedDebtForToken(address token) internal view returns (uint256 total) {
        uint256 next = positionManagerF.getNextPositionId();
        for (uint256 id = 1; id < next; ++id) {
            total += gettersF.getBorrowDetails(id, token); // pooled leg, per-token
            uint256[] memory loans = gettersF.getUserActiveLoanIds(id);
            for (uint256 j; j < loans.length; ++j) {
                (, address loanTok,,,,, uint256 debt,,,) = gettersF.getLoanDetails(loans[j]);
                if (loanTok == token) total += debt; // P2P leg, filtered by loan.token
            }
        }
    }

    /// @dev Funding cap for a loan repayment, scaled to the token's decimals so
    ///      low-decimal vaults still get exercised (2,000,000 whole tokens).
    function _capForToken(address token) internal view returns (uint256) {
        return 2_000_000 * (10 ** ERC20Mock(token).decimals());
    }

    function _fundAndApprove(ERC20Mock token, address actor, uint256 amount) internal {
        token.mint(actor, amount);
        vm.prank(actor);
        token.approve(address(diamond), amount);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _collat(uint256 seed) internal view returns (address) {
        uint256 s = seed % 4;
        if (s == 0) return address(token1);
        if (s == 1) return address(token2);
        if (s == 2) return address(dualTok);
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