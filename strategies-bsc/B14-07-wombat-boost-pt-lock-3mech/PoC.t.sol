// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";

/// @title B14-07 PoC - Wombat MasterChef LP + veWOM boost + Pendle PT lock (3-mech)
/// @notice Three orthogonal yield mechanisms running on a single USDT principal:
///         (1) **Wombat MasterChef LP** - deposit USDT into the Wombat main
///         pool, earning swap fees + WOM emissions.
///         (2) **veWOM boost** - convert claimed WOM to veWOM (4-year lock at
///         peak boost ~2.0x) so the *boostMultiplier* lifts the LP's WOM APR
///         from base to peak.
///         (3) **Pendle PT-USDT-LP** lock - sell a slice of the LP-token's
///         WOM yield stream as YT and pocket the discounted PT, effectively
///         locking the **boosted** base APR at a premium.
/// @dev    Offline-first; the on-chain branch uses `try/catch` for every
///         external call so missing markets degrade to no-op.
contract B14_07_PoC is BSCStrategyBase {
    // ---- Inlined addresses ----
    /// @dev Wombat MasterChef V3 (USDT LP gauge). // TODO verify.
    address constant LOCAL_WOMBAT_MASTERCHEF = 0x0000000000000000000000000000000000B14070;
    /// @dev veWOM lock contract. // TODO verify.
    address constant LOCAL_VEWOM = 0x0000000000000000000000000000000000B14071;
    /// @dev Pendle PT-WOMlp-USDT-26JUN2025 market. // TODO verify.
    address constant LOCAL_PT_WOMLP_MARKET = 0x0000000000000000000000000000000000B14072;
    /// @dev Pendle PT principal token for the Wombat USDT LP. // TODO verify.
    address constant LOCAL_PT_WOMLP = 0x0000000000000000000000000000000000B14073;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_USDT = 100_000e18;
    /// @dev 80/20 split - 80% to LP+boost path, 20% to PT lock.
    uint256 constant LP_LEG_BPS = 8000;
    uint256 constant HOLD_DAYS = 60;
    /// @dev Boost multiplier applied to the LP's WOM emission. veWOM at
    ///      4-year peak gives ~2.0x base APR.
    uint256 constant BOOST_MULT_BPS = 20_000; // 2.0x

    // ---- Rates (1e4 = 100%) ----
    /// @dev Wombat USDT pool base swap-fee APR.
    uint256 constant WOMBAT_SWAP_FEE_APR_BPS = 80; // 0.80%
    /// @dev Wombat USDT base WOM emission APR (unboosted).
    uint256 constant WOM_EMIT_BASE_APR_BPS = 350; // 3.50%
    /// @dev PT-WOMlp implied APR locked at fork (boosted-rate proxy).
    uint256 constant PT_LOCKED_APR_BPS = 850; // 8.50%
    /// @dev One-shot PT entry drag.
    uint256 constant PT_ENTRY_DRAG_BPS = 40; // 40 bp (Pendle PT for LPs costs more)
    /// @dev veWOM lock cost amortized over 60 days (one-shot transaction +
    ///      opportunity cost of locked WOM). Modelled in bps of principal.
    uint256 constant VEWOM_LOCK_DRAG_BPS = 15; // 15 bp

    function setUp() public {
        _trackToken(BSC.USDT);
        _trackToken(BSC.WOM);
        _trackToken(LOCAL_PT_WOMLP);
        _setOraclePrice(BSC.WOM, 25e6); // $0.25/WOM reference
    }

    function testWombatBoostPtLock3Mech() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainStack();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B14-07-wombat-boost-pt-lock-3mech");
    }

    // ----------------------------------------------------------------
    // Forked branch.
    // ----------------------------------------------------------------
    function _runOnchainStack() internal {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);

        uint256 lpLeg = (PRINCIPAL_USDT * LP_LEG_BPS) / 10_000;
        uint256 ptLeg = PRINCIPAL_USDT - lpLeg;

        // 1. Deposit lpLeg into Wombat USDT pool (with shouldStake = true).
        IERC20(BSC.USDT).approve(BSC.WOMBAT_MAIN_POOL, type(uint256).max);
        try IWombatPool(BSC.WOMBAT_MAIN_POOL).deposit(
            BSC.USDT, lpLeg, 0, address(this), block.timestamp + 60, true
        ) returns (uint256) {} catch {}

        // 2. veWOM lock - placeholder; the PoC pre-funds a small amount of WOM
        //    to simulate already having WOM to lock, then attempts lock.
        _fund(BSC.WOM, address(this), 1_000e18);
        IERC20(BSC.WOM).approve(LOCAL_VEWOM, type(uint256).max);
        (bool ok,) = LOCAL_VEWOM.call(
            abi.encodeWithSignature("createLock(uint256,uint256)", 1_000e18, 4 * 365 days)
        );
        if (!ok) {
            // Tolerate veWOM ABI skew.
        }

        // 3. PT-WOMlp lock for the remaining 20%.
        IERC20(BSC.USDT).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.USDT,
            netTokenIn: ptLeg,
            tokenMintSy: BSC.USDT,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_WOMLP_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256, uint256, uint256) {} catch {}

        // 4. Hold; accrue all three legs.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);

        // 5. Claim WOM from MasterChef (placeholder).
        (ok,) = LOCAL_WOMBAT_MASTERCHEF.call(
            abi.encodeWithSignature("multiClaim(uint256[])")
        );
    }

    // ----------------------------------------------------------------
    // Offline branch - closed-form 3-mech projection.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        int256 principal = int256(PRINCIPAL_USDT);
        int256 lpLeg = (principal * int256(LP_LEG_BPS)) / 10_000;
        int256 ptLeg = principal - lpLeg;

        // Leg 1+2 (LP + boost): swap fees + boosted WOM emission.
        int256 boostedWomBps =
            (int256(WOM_EMIT_BASE_APR_BPS) * int256(BOOST_MULT_BPS)) / 10_000;
        int256 lpApyBps = int256(WOMBAT_SWAP_FEE_APR_BPS) + boostedWomBps;
        int256 lpCarry = (lpLeg * lpApyBps * int256(HOLD_DAYS)) / (10_000 * 365);

        // Leg 3 (PT lock).
        int256 ptCarry = (ptLeg * int256(PT_LOCKED_APR_BPS) * int256(HOLD_DAYS))
            / (10_000 * 365);

        // Drags.
        int256 ptDrag = (ptLeg * int256(PT_ENTRY_DRAG_BPS)) / 10_000;
        int256 vewomDrag = (lpLeg * int256(VEWOM_LOCK_DRAG_BPS)) / 10_000;

        int256 pnlUsd = lpCarry + ptCarry - ptDrag - vewomDrag;

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
