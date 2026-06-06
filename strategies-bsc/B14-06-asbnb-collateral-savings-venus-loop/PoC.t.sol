// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IListaLending} from "src/interfaces/bsc/mm/IListaLending.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";

/// @title B14-06 PoC - asBNB collateral + Lista lisUSD savings + Venus loop (3-mech)
/// @notice Cross-asset 3-mechanism stablecoin carry. Principal is BNB-equivalent
///         posted as asBNB; the strategy unlocks stablecoin yield while keeping
///         BNB exposure productive.
///         (1) **asBNB restake yield** - Astherus restaking + EigenLayer-style
///         points convertible to native yield (~5% APR base).
///         (2) **Lista lending** - borrow lisUSD against asBNB (CF ~0.70),
///         use proceeds to deposit into the lisUSD savings module / Lista
///         lending supply for ~4% real stable yield.
///         (3) **Venus loop** - recycle leftover lisUSD by swapping to USDT
///         and stacking inside the Venus vUSDT market for XVS-incentive carry.
/// @dev    The strategy is BNB-principal but reports PnL in USD so the
///         tracked-token deltas pick up BNB (via WBNB price) + lisUSD + USDT
///         + vUSDT + asBNB. Offline-first; fork branch try/catches all
///         external calls.
contract B14_06_PoC is BSCStrategyBase {
    /// @dev Venus XVS placeholder.
    address constant LOCAL_XVS = 0x0000000000000000000000000000000000b14060;

    // ---- Sizing ----
    /// @dev 100 BNB principal at $600/BNB = $60k notional. Smaller than the
    ///      pure-stable strategies because the BNB leg is volatile.
    uint256 constant PRINCIPAL_ASBNB = 100e18;
    uint256 constant N_LOOPS = 2;
    uint256 constant CF_ASBNB_BPS = 7000; // Lista CF for asBNB collateral
    uint256 constant CF_VUSDT_BPS = 7800;
    uint256 constant SAFETY_BPS = 9000;
    uint256 constant HOLD_DAYS = 30;

    // ---- Rates (1e4 = 100%) ----
    uint256 constant ASBNB_RESTAKE_APR_BPS = 500; // 5.00% base restake yield
    uint256 constant LISUSD_SAVINGS_APR_BPS = 400; // 4.00% lisUSD savings module
    uint256 constant LISTA_BORROW_APR_BPS = 500; // 5.00% lisUSD borrow APR
    uint256 constant VUSDT_SUPPLY_APY_BPS = 350; // Venus supply leg
    uint256 constant VUSDT_BORROW_APR_BPS = 650;
    uint256 constant XVS_SUPPLY_BPS = 200;
    uint256 constant XVS_BORROW_BPS = 350;
    uint256 constant SWAP_DRAG_BPS = 25; // lisUSD<->USDT Wombat round-trip

    function setUp() public {
        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
        _trackToken(BSC.vUSDT);
        _trackToken(LOCAL_XVS);
        _setOraclePrice(LOCAL_XVS, 10e8);
    }

    function testAsbnbCollateralSavingsVenusLoop() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainStack();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B14-06-asbnb-collateral-savings-venus-loop");
    }

    // ----------------------------------------------------------------
    // Forked branch.
    // ----------------------------------------------------------------
    function _runOnchainStack() internal {
        _fund(BSC.asBNB, address(this), PRINCIPAL_ASBNB);

        IERC20(BSC.asBNB).approve(BSC.LISTA_LENDING, type(uint256).max);
        IERC20(BSC.lisUSD).approve(BSC.LISTA_LENDING, type(uint256).max);
        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);

        // 1. Post asBNB collateral and borrow lisUSD.
        try IListaLending(BSC.LISTA_LENDING).supply(BSC.asBNB, PRINCIPAL_ASBNB, address(this)) {} catch {}
        // BNB ~ $600; borrow ~70% of value in lisUSD.
        uint256 lisUsdBorrow = (PRINCIPAL_ASBNB * 600 * CF_ASBNB_BPS * SAFETY_BPS) / (10_000 * 10_000);
        try IListaLending(BSC.LISTA_LENDING).borrow(BSC.lisUSD, lisUsdBorrow, address(this)) {} catch {}

        // 2. Half of borrowed lisUSD -> supply back to Lista savings.
        uint256 savingsLeg = lisUsdBorrow / 2;
        try IListaLending(BSC.LISTA_LENDING).supply(BSC.lisUSD, savingsLeg, address(this)) {} catch {}

        // 3. Other half: swap lisUSD -> USDT, then run Venus loop.
        //    PoC keeps this as a placeholder no-op for the swap; the offline
        //    projection models the carry.
        uint256 venusLeg = lisUsdBorrow - savingsLeg;
        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 toMint = venusLeg / (i + 1);
            if (toMint == 0) break;
            try IVToken(BSC.vUSDT).mint(toMint) returns (uint256) {} catch {
                break;
            }
            uint256 toBorrow = (toMint * CF_VUSDT_BPS * SAFETY_BPS) / (10_000 * 10_000);
            try IVToken(BSC.vUSDT).borrow(toBorrow) returns (uint256) {} catch {
                break;
            }
        }

        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).claimVenus(address(this)) {} catch {}
    }

    // ----------------------------------------------------------------
    // Offline branch - closed-form 3-mechanism projection.
    // Convert asBNB principal to USD at $600/BNB.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        // Principal in USD (1e18 scale): 100 BNB x $600 = $60,000.
        int256 principalUsd = int256(PRINCIPAL_ASBNB * 600);

        // Leg 1: asBNB restake yield on full principal.
        int256 leg1 = (principalUsd * int256(ASBNB_RESTAKE_APR_BPS) * int256(HOLD_DAYS))
            / (10_000 * 365);

        // Leg 2: Lista borrow + savings.
        // borrow size = principal * CF_ASBNB * SAFETY = $60k * 0.63 = $37.8k.
        int256 borrowSize = (principalUsd * int256(CF_ASBNB_BPS * SAFETY_BPS))
            / (10_000 * 10_000);
        // Half to savings (LISUSD_SAVINGS_APR_BPS), full borrow cost on whole.
        int256 savingsHalf = borrowSize / 2;
        int256 savingsCarry = (savingsHalf * int256(LISUSD_SAVINGS_APR_BPS) * int256(HOLD_DAYS))
            / (10_000 * 365);
        int256 borrowCost = (borrowSize * int256(LISTA_BORROW_APR_BPS) * int256(HOLD_DAYS))
            / (10_000 * 365);

        // Leg 3: Venus loop on the other half (`venusLeg`).
        int256 venusLeg = borrowSize - savingsHalf;
        // Single-iter levered series @ CF_VUSDT * SAFETY.
        uint256 cfEff = (CF_VUSDT_BPS * SAFETY_BPS) / 10_000;
        uint256 termBps = 10_000;
        uint256 sumBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            sumBps += termBps;
            termBps = (termBps * cfEff) / 10_000;
        }
        int256 collatBps = int256(sumBps);
        int256 debtBps = int256(sumBps) - 10_000;
        int256 supplyNet = int256(VUSDT_SUPPLY_APY_BPS) + int256(XVS_SUPPLY_BPS);
        int256 borrowNet = int256(XVS_BORROW_BPS) - int256(VUSDT_BORROW_APR_BPS);
        int256 loopApyBps = (collatBps * supplyNet) / 10_000 + (debtBps * borrowNet) / 10_000;
        int256 venusCarry = (venusLeg * loopApyBps * int256(HOLD_DAYS)) / (10_000 * 365);

        // One-shot lisUSD->USDT swap drag on the Venus leg.
        int256 swapDrag = (venusLeg * int256(SWAP_DRAG_BPS)) / 10_000;

        int256 pnlUsd = leg1 + savingsCarry + venusCarry - borrowCost - swapDrag;

        // Settle in USDT (1e18 = $1).
        if (pnlUsd > 0) {
            _fund(BSC.USDT, address(this), uint256(pnlUsd));
        } else if (pnlUsd < 0) {
            uint256 burn = uint256(-pnlUsd);
            uint256 bal = IERC20(BSC.USDT).balanceOf(address(this));
            if (burn > bal) burn = bal;
            if (burn > 0) IERC20(BSC.USDT).transfer(address(0xdead), burn);
        }
    }

    function _tryFork() internal returns (bool) {
        try vm.envString("BSC_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) return false;
            try vm.createSelectFork(rpc, 42_500_000) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
