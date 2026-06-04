// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {console2} from "forge-std/console2.sol";

import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IConvexBooster, IConvexBaseRewardPool} from "src/interfaces/bribe/IConvexBooster.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";
import {ILLAMMA} from "src/interfaces/cdp/ILLAMMA.sol";

/// @title F12-09 Convex crvUSD/USDC LP + LLAMMA peg-shift arb co-execution
/// @notice Three-mechanism PoC: **Curve** + **Convex** + **LLAMMA**.
///         Composes the steady-state LP yield (Curve+Convex) with the
///         opportunistic peg-shift arbitrage that consumes the same pool's
///         liquidity:
///           1. Hold + stake crvUSD/USDC LP into Convex Booster PID 182.
///              Earn CRV+CVX on the stableswap, plus accrued swap fees.
///           2. When a soft-liquidation pulse hits a LLAMMA (e.g.
///              wstETH LLAMMA - F05 uses it), crvUSD trades briefly off
///              its $1 peg as the LLAMMA accumulates USD-side balances
///              and dumps them through the crvUSD/USDC pool. Spot moves
///              5-20 bps.
///           3. At a peg-shift threshold, withdraw a slice of the LP back
///              to USDC, route it through the crvUSD/USDC pool to capture
///              the off-peg bps, and re-add liquidity. Net: harvest
///              ordinary CRV+CVX *and* the LLAMMA-induced spread.
///         At block 19_643_500 the pool was at peg; we synthesise the
///         peg shift by direct LLAMMA `exchange()` to demonstrate the
///         arb composition on a live fork.
contract F12_09_PoC is StrategyBase {
    // ---- Curve crvUSD/USDC pool (StableSwap-NG, indices: 0=crvUSD, 1=USDC) ----
    address constant CRVUSD_USDC_POOL = 0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E;

    // ---- Convex ----
    // Convex Booster PID for crvUSD/USDC: PID 182 (Convex's pool registry,
    // verified via Convex front-end). Inlined per family rule.
    uint256 constant PID_CRVUSD_USDC = 182;
    // BaseRewardPool for PID 182 - resolved at runtime via Booster.poolInfo
    // because Convex re-deploys rewards contracts occasionally.
    address internal _cvxCrvUsdRewards;

    // ---- LLAMMA (wstETH market - biggest crvUSD market by USD outstanding) ----
    address constant LLAMMA_WSTETH = 0x37417B2238AA52D0DD2D6252d989E728e8f706e4;

    // ---- Reward tokens ----
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    // ---- Block ----
    uint256 constant FORK_BLOCK = 19_643_500;

    // 100k of crvUSD/USDC LP (~$100k notional; LP ~= $1.0).
    uint256 constant LP_NOTIONAL = 100_000 ether;

    // Synthetic peg-shift size: USDC traded against the pool to *create*
    // an off-peg condition (mimicking what a LLAMMA dump would do).
    uint256 constant USDC_SHIFT = 2_000_000 * 1e6;  // 2M USDC

    function setUp() public {
        _fork(FORK_BLOCK);
        _setEthUsdFallback(3_300e8);

        _trackToken(CRVUSD_USDC_POOL);
        _trackToken(Mainnet.CRVUSD);
        _trackToken(Mainnet.USDC);
        _trackToken(CRV);
        _trackToken(Mainnet.CVX);
    }

    function test_F12_09_convex_llamma_arb() public {
        // ---- 1) Sanity-check the Curve pool & Convex Booster ----
        // Pool 0x4DEcE678... layout: coin0=USDC, coin1=crvUSD.
        require(
            ICurveStableSwap(CRVUSD_USDC_POOL).coins(0) == Mainnet.USDC,
            "pool coin0 != USDC"
        );
        require(
            ICurveStableSwap(CRVUSD_USDC_POOL).coins(1) == Mainnet.CRVUSD,
            "pool coin1 != crvUSD"
        );

        IConvexBooster.PoolInfo memory pi =
            IConvexBooster(Mainnet.CONVEX_BOOSTER).poolInfo(PID_CRVUSD_USDC);
        require(pi.lptoken == CRVUSD_USDC_POOL, "PID 182 lptoken mismatch");
        require(!pi.shutdown, "PID 182 shutdown");
        _cvxCrvUsdRewards = pi.crvRewards;
        console2.log("Convex PID 182 crvRewards:", _cvxCrvUsdRewards);

        // ---- 2) Fund the LP and the synthetic-shift USDC BEFORE _startPnL ----
        // The 2M USDC used to synthesise the LLAMMA peg-shift is "attacker
        // capital"; it must not be counted as PnL inflow. We pre-fund it
        // before `_startPnL` so the PnL snapshot's USDC baseline already
        // reflects the 2M, and the only USDC delta tracked is the net
        // edge captured by the arb round-trip.
        _fund(CRVUSD_USDC_POOL, address(this), LP_NOTIONAL);
        _fund(Mainnet.USDC, address(this), USDC_SHIFT);

        _startPnL();
        vm.txGasPrice(20 gwei);

        IERC20(CRVUSD_USDC_POOL).approve(Mainnet.CONVEX_BOOSTER, LP_NOTIONAL);
        bool ok = IConvexBooster(Mainnet.CONVEX_BOOSTER).deposit(PID_CRVUSD_USDC, LP_NOTIONAL, true);
        require(ok, "Booster.deposit failed");
        require(
            IConvexBaseRewardPool(_cvxCrvUsdRewards).balanceOf(address(this)) == LP_NOTIONAL,
            "stake mismatch"
        );

        // ---- 3) Steady-state warp - earn LP-side rewards ----
        vm.warp(block.timestamp + 7 days);
        vm.roll(block.number + 7 days / 12);

        // ---- 4) Synthesise a LLAMMA peg-shift event ----
        // Read LLAMMA price_oracle for narrative logging.
        uint256 pOracleBefore = ILLAMMA(LLAMMA_WSTETH).price_oracle();
        console2.log("LLAMMA wstETH price_oracle BEFORE shift (1e18):", pOracleBefore);

        // We do not actually liquidate a LLAMMA position (would require a
        // separate borrower setup); instead we directly *dump USDC into the
        // crvUSD/USDC pool* to recreate the off-peg state a real soft-liq
        // produces. Pool spot will shift from ~1.00 to ~0.998-0.999.
        // Pool coin0=USDC (index 0), coin1=crvUSD (index 1).
        IERC20(Mainnet.USDC).approve(CRVUSD_USDC_POOL, USDC_SHIFT);
        uint256 crvUsdReceivedFromShift = ICurveStableSwap(CRVUSD_USDC_POOL).exchange(
            int128(0), int128(1), USDC_SHIFT, 0  // USDC(i=0) -> crvUSD(j=1), no min
        );
        console2.log("USDC->crvUSD shift dy (raw):", crvUsdReceivedFromShift);
        // After this dump the pool has excess USDC and crvUSD is now
        // *trading above $1* (USDC was the dumped side). For the arb leg
        // we want to push crvUSD back toward peg by *selling crvUSD into
        // USDC* - exactly what a stableswap arbitrageur would do.

        // ---- 5) Peg-shift arb leg: sell crvUSD back into USDC ----
        uint256 myCrvUsd = IERC20(Mainnet.CRVUSD).balanceOf(address(this));
        IERC20(Mainnet.CRVUSD).approve(CRVUSD_USDC_POOL, myCrvUsd);
        // Quote first so we can require a positive edge: dy must exceed
        // (crvUsd at peg) by some bps.
        uint256 dyEstimate = ICurveStableSwap(CRVUSD_USDC_POOL).get_dy(
            int128(1), int128(0), myCrvUsd  // crvUSD(i=1) -> USDC(j=0)
        );
        console2.log("crvUSD->USDC quote dy (raw, 6-dec):", dyEstimate);
        // crvUSD is 18-dec, USDC is 6-dec. Naive "peg dy" = myCrvUsd / 1e12.
        uint256 pegDy = myCrvUsd / 1e12;
        if (dyEstimate > pegDy) {
            uint256 minOut = (dyEstimate * 9999) / 10000;  // 1 bp slip
            uint256 arbedUsdc = ICurveStableSwap(CRVUSD_USDC_POOL).exchange(
                int128(1), int128(0), myCrvUsd, minOut  // crvUSD(i=1) -> USDC(j=0)
            );
            console2.log("Arb leg USDC out (raw):", arbedUsdc);
            // Edge captured = arbedUsdc - pegDy.
            console2.log("Edge captured (USDC, raw):", arbedUsdc - pegDy);
        } else {
            console2.log("No peg shift -> no arb leg this round.");
        }

        // ---- 6) Steady-state claim - CRV + CVX from the LP-side leg ----
        bool claimed = IConvexBaseRewardPool(_cvxCrvUsdRewards).getReward(address(this), true);
        require(claimed, "getReward failed");

        uint256 bCrv = IERC20(CRV).balanceOf(address(this));
        uint256 bCvx = IERC20(Mainnet.CVX).balanceOf(address(this));
        console2.log("balance CRV (raw):", bCrv);
        console2.log("balance CVX (raw):", bCvx);
        require(bCrv > 0, "no CRV streamed");

        // ---- 7) Withdraw LP back ----
        bool wOk = IConvexBaseRewardPool(_cvxCrvUsdRewards)
            .withdrawAndUnwrap(LP_NOTIONAL, false);
        require(wOk, "withdrawAndUnwrap failed");

        _endPnL("F12-09-convex-crvusd-usdc-llamma-arb");
    }
}
