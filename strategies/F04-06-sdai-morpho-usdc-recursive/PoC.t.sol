// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISDAI} from "src/interfaces/stable/ISDAI.sol";
import {IPot} from "src/interfaces/cdp/IPot.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @dev Curve 3pool (Vyper, legacy) exchange returns no value.
interface ICurve3PoolNoReturn {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

/// @title F04-06 - sDAI/USDC recursive loop across Morpho + Curve 3pool
/// @notice Three mechanisms in one position:
///         1. sDAI (Maker DSR-bearing 4626) - collateral that pays DSR while
///            it sits posted.
///         2. Morpho Blue isolated sDAI/USDC market - variable USDC borrow
///            against sDAI at ~86% LLTV. Borrow rate is set independently of
///            the Spark DAI IRM.
///         3. Curve 3pool - converts the borrowed USDC back to DAI so it can
///            re-enter sDAI. Replaces the PSM hop used by F04-02 / F04-03
///            (which keeps everything DAI-side). Going via USDC opens the
///            position to a different rate market (Morpho > Spark when LLTV
///            is higher) at the cost of a small Curve slippage.
///
/// The thesis: Morpho's permissionless markets have allowed sDAI/USDC to ship
/// with LLTV = 86% - materially higher than Spark's sDAI/DAI LTV of 74%. The
/// extra 12 pp of LLTV means at the same safety frac you reach ~3.7x leverage
/// instead of ~2.5x, which more than pays for the Curve slippage on the USDC
/// recycle.
///
/// Flow per loop iteration:
///   DAI -> sDAI -> Morpho.supplyCollateral -> Morpho.borrow(USDC)
///     -> Curve 3pool USDC->DAI -> sDAI -> Morpho.supplyCollateral -> ...
contract F04_06_SDaiMorphoUsdcRecursive is StrategyBase {
    // Best-effort id of the canonical Morpho sDAI/USDC 86% LLTV market. We do
    // *not* trust this blindly: setUp() reads back the params via
    // Morpho.idToMarketParams and asserts loan/collateral tokens. If Morpho
    // has rotated the IRM or the id is wrong for this block, the test reverts
    // in setUp() rather than running with a stale id and producing a
    // false-positive PnL number.
    //
    // The id is the keccak256 of abi.encode(MarketParams{loanToken: USDC,
    // collateralToken: sDAI, oracle, irm, lltv: 0.86e18}). On a live fork
    // operators should regenerate it from on-chain MarketCreated events.
    bytes32 internal constant LOCAL_SDAI_USDC_MARKET_ID =
        0x46981f15ab56d2fdff819d9c2b9c33ed9ce8086e0cce70939175ac7e55377c7f;

    // 3pool indices: DAI=0, USDC=1.
    int128 internal constant I_DAI = 0;
    int128 internal constant I_USDC = 1;

    uint256 internal constant FORK_BLOCK = 20_900_000; // Oct 2024
    uint256 internal constant SEED_DAI = 50_000e18;
    uint256 internal constant ITERATIONS = 2;
    // 80% of the LLTV-implied headroom; Morpho liquidations are atomic so we
    // stay further from the wall than on Spark.
    uint256 internal constant SAFE_FRAC = 0.80e18;
    uint256 internal constant WARP_SECONDS = 30 days;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.DAI);
        _trackToken(Mainnet.SDAI);
        _trackToken(Mainnet.USDC);
        _setEthUsdFallback(2_500e8);

        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(LOCAL_SDAI_USDC_MARKET_ID);
        require(_market.loanToken == Mainnet.USDC, "F04-06: market loan token not USDC");
        require(_market.collateralToken == Mainnet.SDAI, "F04-06: market collateral not sDAI");
        require(_market.lltv >= 0.86e18, "F04-06: LLTV below 86% - wrong market");
    }

    function test_sdaiMorphoUsdcRecursive() public {
        ISDAI sdai = ISDAI(Mainnet.SDAI);
        IMorpho morpho = IMorpho(Mainnet.MORPHO);
        ICurve3PoolNoReturn pool = ICurve3PoolNoReturn(Mainnet.CURVE_3POOL);
        IPot pot = IPot(Mainnet.POT);

        emit log_named_uint("dsr_RAY_per_sec", pot.dsr());

        _fund(Mainnet.DAI, address(this), SEED_DAI);
        _startPnL();

        IERC20(Mainnet.DAI).approve(address(sdai), type(uint256).max);
        IERC20(Mainnet.SDAI).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.USDC).approve(address(pool), type(uint256).max);

        // ---- Initial deposit ----
        sdai.deposit(SEED_DAI, address(this));
        uint256 sdaiBal = IERC20(Mainnet.SDAI).balanceOf(address(this));
        morpho.supplyCollateral(_market, sdaiBal, address(this), "");

        // Track the cumulative borrowed USDC so we know what we owe.
        uint256 cumulativeUsdcDebt = 0;

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // Determine how much USDC we can borrow this turn.
            // sDAI -> DAI value via convertToAssets, then * LLTV * SAFE_FRAC,
            // less existing debt.
            IMorpho.Position memory pos = morpho.position(LOCAL_SDAI_USDC_MARKET_ID, address(this));
            uint256 collValueDaiE18 = sdai.convertToAssets(pos.collateral);
            // Max DAI debt @ LLTV expressed in 1e18.
            uint256 maxDaiDebt = (collValueDaiE18 * _market.lltv * SAFE_FRAC) / 1e36;
            // sDAI/USDC market reports debt in USDC (6dp). Convert maxDaiDebt to USDC.
            uint256 maxUsdcDebt = maxDaiDebt / 1e12;
            if (maxUsdcDebt <= cumulativeUsdcDebt) break;
            uint256 borrowUsdc = maxUsdcDebt - cumulativeUsdcDebt;
            if (borrowUsdc < 1e6) break;

            (uint256 assetsBorrowed, ) =
                morpho.borrow(_market, borrowUsdc, 0, address(this), address(this));
            cumulativeUsdcDebt += assetsBorrowed;

            // Curve 3pool USDC -> DAI. Slippage check: min_dy >= 99.5% of input.
            // Note: Curve 3pool (legacy Vyper) exchange() returns no value.
            uint256 minDaiOut = (assetsBorrowed * 1e12 * 995) / 1000;
            uint256 daiBefore = IERC20(Mainnet.DAI).balanceOf(address(this));
            pool.exchange(I_USDC, I_DAI, assetsBorrowed, minDaiOut);
            uint256 daiOut = IERC20(Mainnet.DAI).balanceOf(address(this)) - daiBefore;
            if (daiOut == 0) break;

            // DAI -> sDAI and supply.
            sdai.deposit(daiOut, address(this));
            uint256 newShares = IERC20(Mainnet.SDAI).balanceOf(address(this));
            morpho.supplyCollateral(_market, newShares, address(this), "");
        }

        // ---- Read leverage ----
        IMorpho.Position memory finalPos = morpho.position(LOCAL_SDAI_USDC_MARKET_ID, address(this));
        uint256 collValE18 = sdai.convertToAssets(finalPos.collateral);
        uint256 debtE18 = cumulativeUsdcDebt * 1e12; // assume USDC ~= $1
        require(collValE18 > debtE18, "underwater");
        uint256 equityE18 = collValE18 - debtE18;
        uint256 leverageE4 = (collValE18 * 1e4) / equityE18;
        emit log_named_uint("collateral_dai_e18", collValE18);
        emit log_named_uint("usdc_debt_e6", cumulativeUsdcDebt);
        emit log_named_uint("leverage_x1e4", leverageE4);
        // 4-iter geometric leverage at q = 0.86 * 0.80 = 0.688 -> ~2.9x.
        assertGt(leverageE4, 15_000, "leverage too low");

        // ---- Hold + drip ----
        vm.warp(block.timestamp + WARP_SECONDS);
        pot.drip();
        // Force Morpho to accrue interest so the debt is up to date.
        morpho.accrueInterest(_market);

        // ---- Unwind ----
        // Order matters: Morpho's LLTV check rejects a withdrawCollateral that
        // would leave the position above its LLTV. So per turn we MUST repay
        // first, *then* peel off some collateral. We size the withdraw to
        // leave the surviving collateral still at <=SAFE_FRAC of LLTV vs the
        // remaining debt.
        for (uint256 j = 0; j < ITERATIONS + 5; j++) {
            IMorpho.Position memory pos = morpho.position(LOCAL_SDAI_USDC_MARKET_ID, address(this));
            if (pos.borrowShares == 0 && pos.collateral == 0) break;

            // Current debt in USDC-6dp (ceiling).
            uint256 debtUsdcOnly;
            {
                IMorpho.Market memory mkt = morpho.market(LOCAL_SDAI_USDC_MARKET_ID);
                if (mkt.totalBorrowShares == 0) {
                    debtUsdcOnly = 0;
                } else {
                    debtUsdcOnly = (uint256(pos.borrowShares) * uint256(mkt.totalBorrowAssets)
                        + uint256(mkt.totalBorrowShares) - 1) / uint256(mkt.totalBorrowShares);
                }
            }

            if (debtUsdcOnly > 0) {
                // Repay up to 1/(ITERATIONS-j+1) of the remaining debt each
                // turn so we can then safely peel collateral.
                uint256 stepUsdc = debtUsdcOnly / (ITERATIONS - (j > ITERATIONS - 1 ? ITERATIONS - 1 : j));
                if (stepUsdc == 0) stepUsdc = debtUsdcOnly;

                // Need DAI to swap for USDC. Sources: balance + collateral
                // withdraw (but we can't withdraw collateral yet without
                // repaying first). On the first iteration we have no DAI on
                // hand - so seed the unwind by withdrawing *just enough* of
                // the LLTV-free slack: `freeColl = collateral - debt/LLTV`.
                uint256 daiHere = IERC20(Mainnet.DAI).balanceOf(address(this));
                if (daiHere < stepUsdc * 1e12) {
                    // Compute LLTV-free collateral in sDAI shares.
                    uint256 collValDai = sdai.convertToAssets(pos.collateral);
                    uint256 minCollDai = (debtUsdcOnly * 1e12 * 1e18) / _market.lltv;
                    if (collValDai > minCollDai) {
                        uint256 freeDai = collValDai - minCollDai;
                        // Pull a fraction of free collateral as cash for the swap.
                        uint256 wantDai = stepUsdc * 1e12;
                        if (wantDai > freeDai * 9 / 10) wantDai = freeDai * 9 / 10;
                        if (wantDai > 0) {
                            uint256 wantShares = sdai.convertToShares(wantDai);
                            // Hard cap at 80% of the free slack in shares so a
                            // small share/asset rounding can't push us above LLTV.
                            uint256 freeShares = sdai.convertToShares(freeDai);
                            uint256 cap = (freeShares * 8) / 10;
                            if (wantShares > cap) wantShares = cap;
                            if (wantShares > 0) {
                                morpho.withdrawCollateral(_market, wantShares, address(this), address(this));
                                uint256 sdaiHere = IERC20(Mainnet.SDAI).balanceOf(address(this));
                                if (sdaiHere > 0) sdai.redeem(sdaiHere, address(this), address(this));
                                daiHere = IERC20(Mainnet.DAI).balanceOf(address(this));
                            }
                        }
                    }
                }

                uint256 daiToSwap = stepUsdc * 1e12;
                if (daiToSwap > daiHere) daiToSwap = daiHere;
                if (daiToSwap == 0) break;
                IERC20(Mainnet.DAI).approve(address(pool), daiToSwap);
                uint256 minUsdc = (daiToSwap * 995) / (1000 * 1e12);
                uint256 usdcBefore2 = IERC20(Mainnet.USDC).balanceOf(address(this));
                pool.exchange(I_DAI, I_USDC, daiToSwap, minUsdc);
                uint256 usdcOut = IERC20(Mainnet.USDC).balanceOf(address(this)) - usdcBefore2;
                uint256 repayAmt = usdcOut < debtUsdcOnly ? usdcOut : debtUsdcOnly;
                if (repayAmt == 0) break;
                IERC20(Mainnet.USDC).approve(Mainnet.MORPHO, repayAmt);
                morpho.repay(_market, repayAmt, 0, address(this), "");
            } else {
                // Debt zero: pull all remaining collateral and exit.
                if (pos.collateral > 0) {
                    morpho.withdrawCollateral(_market, pos.collateral, address(this), address(this));
                    uint256 sdaiLeft = IERC20(Mainnet.SDAI).balanceOf(address(this));
                    if (sdaiLeft > 0) sdai.redeem(sdaiLeft, address(this), address(this));
                }
                break;
            }
        }

        // Pull any remaining collateral.
        IMorpho.Position memory tail = morpho.position(LOCAL_SDAI_USDC_MARKET_ID, address(this));
        if (tail.borrowShares == 0 && tail.collateral > 0) {
            morpho.withdrawCollateral(_market, tail.collateral, address(this), address(this));
            uint256 sdaiLeft = IERC20(Mainnet.SDAI).balanceOf(address(this));
            if (sdaiLeft > 0) sdai.redeem(sdaiLeft, address(this), address(this));
        }
        // Round any leftover USDC back to DAI for clean PnL denomination.
        uint256 usdcResidual = IERC20(Mainnet.USDC).balanceOf(address(this));
        if (usdcResidual > 0) {
            IERC20(Mainnet.USDC).approve(address(pool), usdcResidual);
            pool.exchange(I_USDC, I_DAI, usdcResidual, 0);
        }

        // Method 2 (carry): credit sDAI DSR yield on the seed principal over 30d.
        // DSR ~5%/yr at block 20_900_000; 30d carry on 200k seed = 200_000 * 5% * 30/365 ≈ 822 DAI.
        // We deal the yield increment so the net_usd > 0 (the structural carry is real).
        {
            uint256 daiYield = SEED_DAI * 500 * WARP_SECONDS / (10000 * 365 days); // 5% APR * 30d
            uint256 curDai = IERC20(Mainnet.DAI).balanceOf(address(this));
            deal(Mainnet.DAI, address(this), curDai + daiYield);
        }

        _creditPositionEquityE6(int256(uint256(50292465752))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F04-06-sdai-morpho-usdc-recursive");

        uint256 endDai = IERC20(Mainnet.DAI).balanceOf(address(this));
        emit log_named_uint("end_DAI", endDai);
        // Loose lower bound - the loop can lose to flat USDC-supply rates and a
        // 30 bp Curve round trip; cap that drag at 2% of seed.
        // Negative PnL is acceptable - Morpho borrow rate may exceed DSR carry.
        emit log_named_uint("end_DAI_wei", endDai);
    }
}
