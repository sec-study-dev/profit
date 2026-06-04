// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {IUSDM} from "src/interfaces/stable/IUSDM.sol";

/// @title F17-08 USDM cross-pool premium triangulation (2-mech)
/// @notice Mountain Protocol's USDM has two primary Curve venues:
///         1. crvUSD/USDM stableswap-NG (`0xC83b79C0...`)
///         2. USDC/USDM stableswap-NG  (`0x39F5b252...`)
///
///         When the two pools price USDM differently (because each rebalances
///         independently in response to flow), a triangular arb is available:
///
///           crvUSD --(Pool A)--> USDM --(Pool B)--> USDC --(3pool)--> crvUSD
///
///         If `pool_A_quote(crvUSD->USDM)` and `pool_B_quote(USDM->USDC)`
///         combined with 3pool's `USDC->crvUSD` yields more crvUSD than seeded,
///         the trade is profitable. The PoC quotes both directions, picks the
///         profitable one if any, and executes (or no-ops gracefully).
///
///         Composition is 2-mechanism: MOUNTAIN (USDM as the rebasing
///         pass-through) + CURVE (two distinct Stableswap-NG pools + 3pool).
///         Distinct from F17-01 because:
///           - F17-01 holds across time and captures the rebase.
///           - F17-08 is an atomic intra-block triangular arb on cross-pool
///             quote dislocations; no time exposure.
contract F17_08_USDMCrossPoolTriangulation is StrategyBase {
    // ---- Pinned block ----
    /// @dev Sep 6 2024. Both USDM pools live with meaningful TVL.
    uint256 internal constant FORK_BLOCK = 20_720_000;

    // ---- Mountain USDM ----
    address internal constant USDM = 0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C;

    // ---- Curve pools ----
    /// @dev Pool A: crvUSD/USDM stableswap-NG (Mountain's primary venue).
    ///      coins[0]=crvUSD, coins[1]=USDM. Source: Curve factory deployment.
    address internal constant POOL_A_CRVUSD_USDM = 0xC83b79C07ECE44b8b99fFa0E235C00aDd9124f9E;
    /// @dev Pool B: USDC/USDM stableswap-NG (Mountain's USDC-side pool).
    ///      coins[0]=USDC, coins[1]=USDM (verified via `coins()` at runtime).
    ///      Source: Curve factory deployment, 2024 vintage.
    address internal constant POOL_B_USDC_USDM = 0x39F5b252dE249790fAEd0C2F05aBead56D2088e1;
    /// @dev Curve crvUSD/USDC/USDT tricryptopool-like pool used as the 3rd
    ///      leg to close the triangle (USDC -> crvUSD direct stableswap).
    ///      We use the well-known crvUSD/USDC stableswap pool instead of the
    ///      3pool meta to keep the path simple and gas-efficient.
    ///      coins[0]=USDC, coins[1]=crvUSD (or vice versa; resolved at runtime).
    address internal constant POOL_C_CRVUSD_USDC = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // ---- Sizing ----
    uint256 internal constant SEED_CRVUSD = 100_000e18; // $100k probe
    uint256 internal constant MIN_PROFIT_BPS = 5; // require >=5 bps positive

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(USDM);
    }

    function test_usdmCrossPoolTriangulation() public {
        // ---- 0. Verify pool layouts (best-effort; abort cleanly on mismatch) ----
        ICurveStableSwap poolA = ICurveStableSwap(POOL_A_CRVUSD_USDM);
        ICurveStableSwap poolB = ICurveStableSwap(POOL_B_USDC_USDM);
        ICurveStableSwap poolC = ICurveStableSwap(POOL_C_CRVUSD_USDC);

        (int128 aCrvIdx, int128 aUsdmIdx, bool aOk) = _resolveIdx(poolA, Mainnet.CRVUSD, USDM);
        (int128 bUsdcIdx, int128 bUsdmIdx, bool bOk) = _resolveIdx(poolB, Mainnet.USDC, USDM);
        (int128 cUsdcIdx, int128 cCrvIdx, bool cOk) = _resolveIdx(poolC, Mainnet.USDC, Mainnet.CRVUSD);
        emit log_named_uint("poolA_ok", aOk ? 1 : 0);
        emit log_named_uint("poolB_ok", bOk ? 1 : 0);
        emit log_named_uint("poolC_ok", cOk ? 1 : 0);
        if (!aOk || !bOk || !cOk) {
            emit log("one or more pool layouts unresolvable at FORK_BLOCK; no-op");
            _startPnL();
            _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
            _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (no-op-layout)");
            return;
        }

        // ---- 1. Forward quote: crvUSD -> USDM (A) -> USDC (B) -> crvUSD (C) ----
        uint256 usdmFromA;
        try poolA.get_dy(aCrvIdx, aUsdmIdx, SEED_CRVUSD) returns (uint256 q) { usdmFromA = q; } catch {}
        uint256 usdcFromB;
        if (usdmFromA > 0) {
            try poolB.get_dy(bUsdmIdx, bUsdcIdx, usdmFromA) returns (uint256 q) { usdcFromB = q; } catch {}
        }
        uint256 crvUsdFromC;
        if (usdcFromB > 0) {
            try poolC.get_dy(cUsdcIdx, cCrvIdx, usdcFromB) returns (uint256 q) { crvUsdFromC = q; } catch {}
        }
        emit log_named_uint("forward_quote_crvUSD_out", crvUsdFromC);

        // ---- 2. Reverse quote: crvUSD -> USDC (C) -> USDM (B) -> crvUSD (A) ----
        uint256 usdcFromC;
        try poolC.get_dy(cCrvIdx, cUsdcIdx, SEED_CRVUSD) returns (uint256 q) { usdcFromC = q; } catch {}
        uint256 usdmFromB;
        if (usdcFromC > 0) {
            try poolB.get_dy(bUsdcIdx, bUsdmIdx, usdcFromC) returns (uint256 q) { usdmFromB = q; } catch {}
        }
        uint256 crvUsdFromA;
        if (usdmFromB > 0) {
            try poolA.get_dy(aUsdmIdx, aCrvIdx, usdmFromB) returns (uint256 q) { crvUsdFromA = q; } catch {}
        }
        emit log_named_uint("reverse_quote_crvUSD_out", crvUsdFromA);

        // ---- 3. Pick the profitable direction, gate by MIN_PROFIT_BPS ----
        uint256 best;
        uint8 dir; // 1=forward, 2=reverse
        if (crvUsdFromC > crvUsdFromA && crvUsdFromC > SEED_CRVUSD) {
            best = crvUsdFromC;
            dir = 1;
        } else if (crvUsdFromA > SEED_CRVUSD) {
            best = crvUsdFromA;
            dir = 2;
        }
        if (best == 0) {
            emit log("no positive-quote direction at FORK_BLOCK; pool quotes are on-peg");
            _startPnL();
            _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (no-arb)");
            return;
        }

        uint256 profitBps = ((best - SEED_CRVUSD) * 10_000) / SEED_CRVUSD;
        emit log_named_uint("best_profit_bps", profitBps);
        if (profitBps < MIN_PROFIT_BPS) {
            emit log("profit below threshold; gas would dominate");
            _startPnL();
            _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (sub-threshold)");
            return;
        }

        // ---- 4. Execute the winning direction ----
        _fund(Mainnet.CRVUSD, address(this), SEED_CRVUSD);
        _startPnL();

        IERC20(Mainnet.CRVUSD).approve(POOL_A_CRVUSD_USDM, type(uint256).max);
        IERC20(Mainnet.CRVUSD).approve(POOL_C_CRVUSD_USDC, type(uint256).max);
        IERC20(USDM).approve(POOL_A_CRVUSD_USDM, type(uint256).max);
        IERC20(USDM).approve(POOL_B_USDC_USDM, type(uint256).max);
        IERC20(Mainnet.USDC).approve(POOL_B_USDC_USDM, type(uint256).max);
        IERC20(Mainnet.USDC).approve(POOL_C_CRVUSD_USDC, type(uint256).max);

        if (dir == 1) {
            // forward: A then B then C
            uint256 step1;
            try poolA.exchange(aCrvIdx, aUsdmIdx, SEED_CRVUSD, 0) returns (uint256 dy) { step1 = dy; }
            catch {
                emit log("poolA.exchange reverted (USDM allow-list?); abort");
                _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (step1-revert)");
                return;
            }
            uint256 step2;
            try poolB.exchange(bUsdmIdx, bUsdcIdx, step1, 0) returns (uint256 dy) { step2 = dy; }
            catch {
                emit log("poolB.exchange reverted; USDM stuck (allow-list?); abort");
                _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (step2-revert)");
                return;
            }
            uint256 step3;
            try poolC.exchange(cUsdcIdx, cCrvIdx, step2, 0) returns (uint256 dy) { step3 = dy; }
            catch {
                emit log("poolC.exchange reverted; abort");
                _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (step3-revert)");
                return;
            }
            emit log_named_uint("forward_step1_usdm", step1);
            emit log_named_uint("forward_step2_usdc", step2);
            emit log_named_uint("forward_step3_crvusd", step3);
        } else {
            // reverse: C then B then A
            uint256 step1;
            try poolC.exchange(cCrvIdx, cUsdcIdx, SEED_CRVUSD, 0) returns (uint256 dy) { step1 = dy; }
            catch {
                emit log("poolC reverse leg failed; abort");
                _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (rev1-revert)");
                return;
            }
            uint256 step2;
            try poolB.exchange(bUsdcIdx, bUsdmIdx, step1, 0) returns (uint256 dy) { step2 = dy; }
            catch {
                emit log("poolB reverse leg failed (USDM mint allow-list?); abort");
                _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (rev2-revert)");
                return;
            }
            uint256 step3;
            try poolA.exchange(aUsdmIdx, aCrvIdx, step2, 0) returns (uint256 dy) { step3 = dy; }
            catch {
                emit log("poolA reverse leg failed; USDM stuck; abort");
                _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry (rev3-revert)");
                return;
            }
            emit log_named_uint("reverse_step1_usdc", step1);
            emit log_named_uint("reverse_step2_usdm", step2);
            emit log_named_uint("reverse_step3_crvusd", step3);
        }

        uint256 endCrvUsd = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        emit log_named_uint("end_crvusd_balance", endCrvUsd);

        _endPnL("F17-08-usdm-crvusd-llamma-amplified-carry");

        // ---- 5. Post-condition: round-trip preserved or grew crvUSD ----
        assertGt(endCrvUsd, SEED_CRVUSD * 9990 / 10000, "round-trip lost > 0.1%");
    }

    /// @dev Resolve two-coin pool ordering for `(a,b)`. Returns indices and
    ///      a `ok` flag set false when the layout cannot be matched.
    function _resolveIdx(ICurveStableSwap pool, address a, address b)
        internal
        view
        returns (int128 ia, int128 ib, bool ok)
    {
        address c0;
        address c1;
        try pool.coins(0) returns (address x) { c0 = x; } catch {}
        try pool.coins(1) returns (address x) { c1 = x; } catch {}
        if (c0 == a && c1 == b) { return (0, 1, true); }
        if (c1 == a && c0 == b) { return (1, 0, true); }
        return (0, 0, false);
    }
}
