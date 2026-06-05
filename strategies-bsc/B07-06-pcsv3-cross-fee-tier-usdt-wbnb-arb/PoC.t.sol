// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPancakeV3Pool, IPancakeV3FlashCallback} from "src/interfaces/bsc/amm/IPancakeV3Pool.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

/// @title B07-06 Cross-fee-tier PCS v3 arb (USDT/WBNB 0.01% vs 0.05% vs 0.25%)
/// @notice The same token pair on UniswapV3 can have multiple fee tiers
///         deployed simultaneously. On BSC, USDT/WBNB has three live pools:
///         100 (0.01%), 500 (0.05%), and 2500 (0.25%). Each pool maintains
///         its OWN sqrtPriceX96; arbitrageurs balance them but never
///         perfectly because:
///           - The 0.01% pool is the deepest and most actively arbed.
///           - The 0.05% pool catches mid-size flow and is the canonical
///             venue for aggregator routing.
///           - The 0.25% pool is shallow but still receives long-tail flow
///             and accumulates micro-deviations between arbed re-syncs.
///         When all three diverge, a single-direction round-trip across
///         two tiers can capture 2-10 bps of spread net of the SUM of
///         their fees. Edge condition: |mid_a - mid_b| > fee_a + fee_b +
///         flash_fee.
/// @dev    Mechanism count: 2 (PCS v3 flash + PCS v3 swap on a different
///         fee tier). Note: this is the SAME protocol on both legs, but
///         the two pools are independent AMMs (different `sqrtPriceX96`).
///         Same-DEX cross-tier arb is conceptually distinct from
///         cross-DEX arb because there's no THE/CAKE governance lag -
///         only LP-positioning-curve lag.
contract B07_06_PcsV3CrossFeeTierArbTest is BSCStrategyBase, IPancakeV3FlashCallback {
    uint256 internal constant FORK_BLOCK = 42_000_000;

    /// @dev PCS v3 USDT/WBNB pools at three fee tiers. WBNB (0xbb4C...) <
    ///      USDT (0x55d3...)? - actually 0x55 < 0xbb, so USDT < WBNB by
    ///      hex; pool sets token0 = USDT, token1 = WBNB? No: lex order in
    ///      hex puts 0x55d3 < 0xbb4C, so token0 = USDT. But B07-01 sets
    ///      token0 = WBNB for the 0.01% pool - verified there empirically
    ///      against BscScan. So token0 = WBNB, token1 = USDT for the
    ///      canonical PCS v3 USDT/WBNB pools (matching B07-01).
    address internal constant PCS_V3_WBNB_USDT_100 = 0x172fcD41E0913e95784454622d1c3724f546f849;
    /// @dev Placeholder - Wave 3 verify via `IPancakeV3Factory.getPool(WBNB, USDT, 500)`.
    address internal constant PCS_V3_WBNB_USDT_500 = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    /// @dev Placeholder - Wave 3 verify via `IPancakeV3Factory.getPool(WBNB, USDT, 2500)`.
    address internal constant PCS_V3_WBNB_USDT_2500 = 0x85FAac652b707FDf6907EF726751087F9E0b6687;

    uint24 internal constant FEE_100 = 100;
    uint24 internal constant FEE_500 = 500;
    uint24 internal constant FEE_2500 = 2500;

    /// @dev Flash WBNB notional. 100 WBNB ~ $60k @ $600/BNB; sized so a
    ///      micro-spread of 5 bps still yields a meaningful absolute PnL.
    uint256 internal constant FLASH_NOTIONAL_WBNB = 100 ether;

    /// @dev Minimum net spread after summed swap fees + flash fee, in bps.
    ///      For the 100 <-> 500 tier pair: flash 1bp + return-swap fee tier
    ///      adds to the routed-leg fee. We compute MIN as defensive floor.
    uint256 internal constant MIN_NET_EDGE_BPS = 2;

    /// @dev Encode which pair of tiers we're arbing - picked dynamically
    ///      based on the largest spread at quote time.
    struct Route {
        address flashPool;     // pool we flash WBNB from
        uint24  flashFeeTier;  // its swap-fee tier (used to compute flash fee)
        address swapPool;      // pool we round-trip WBNB through
        uint24  swapFeeTier;   // its swap-fee tier
        bool    flashWbnbIsToken0; // ordering on flashPool
        bool    sellLegOnSwapPool; // direction: true => WBNB->USDT on swap pool first
    }

    bool internal _flashActive;
    Route internal _activeRoute;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B07_06() public {
        // Read all three mids (USDT per WBNB, 1e18).
        uint256 m100  = _midOf(PCS_V3_WBNB_USDT_100);
        uint256 m500  = _midOf(PCS_V3_WBNB_USDT_500);
        uint256 m2500 = _midOf(PCS_V3_WBNB_USDT_2500);

        emit log_named_uint("B07-06: mid_100_1e18",  m100);
        emit log_named_uint("B07-06: mid_500_1e18",  m500);
        emit log_named_uint("B07-06: mid_2500_1e18", m2500);

        // Find the largest spread across the three tier pairs. We arb the
        // (low_pool, high_pool) ordered pair; flash from the LOW (cheap-WBNB)
        // tier means we'd sell WBNB cheap and buy back high -> unprofitable.
        // Correct direction: sell WBNB on the pool that PAYS MORE USDT (high
        // mid), buy it back on the pool that's CHEAPER (low mid).
        // Flash source = pool we sell INTO = high-mid pool. Return-swap pool
        // = the low-mid pool where we buy WBNB back.
        (address highPool, uint24 highFee, address lowPool, uint24 lowFee, uint256 spreadBps) =
            _pickBestPair(m100, m500, m2500);

        emit log_named_uint("B07-06: best_spread_bps_raw", spreadBps);

        // Net edge after both swap fees (sell + buy = sum of fee tiers) and
        // the flash fee (paid on the FLASH pool, which is `highPool`).
        uint256 totalFeeBps = uint256(highFee) / 100 + uint256(lowFee) / 100 + uint256(highFee) / 100; // bps
        // Note: the FLASH fee on a PCS v3 pool equals the pool's swap-fee
        // tier (e.g. 100 = 1 bp). We pay it ON TOP of the swap-fee on the
        // sell leg in `highPool`. So fee load = sell_swap + buy_swap + flash.
        if (spreadBps <= totalFeeBps + MIN_NET_EDGE_BPS) {
            emit log_string("B07-06: skipped (spread below summed fees + min edge)");
            return;
        }
        uint256 netEdgeBps = spreadBps - totalFeeBps;
        emit log_named_uint("B07-06: net_edge_bps", netEdgeBps);

        // Resolve pool token orderings for flash arg.
        bool wbnbIsToken0OnHigh = _wbnbIsToken0(highPool);

        _activeRoute = Route({
            flashPool: highPool,
            flashFeeTier: highFee,
            swapPool: lowPool,
            swapFeeTier: lowFee,
            flashWbnbIsToken0: wbnbIsToken0OnHigh,
            sellLegOnSwapPool: false // we already swap on `flashPool` first via Router
        });

        _startPnL();

        _flashActive = true;
        if (wbnbIsToken0OnHigh) {
            IPancakeV3Pool(highPool).flash(address(this), FLASH_NOTIONAL_WBNB, 0, "");
        } else {
            IPancakeV3Pool(highPool).flash(address(this), 0, FLASH_NOTIONAL_WBNB, "");
        }
        _flashActive = false;

        _endPnL("B07-06: PCS v3 cross-fee-tier USDT/WBNB micro-spread arb");
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata /* data */) external override {
        require(_flashActive, "callback: not active");
        Route memory r = _activeRoute;
        require(msg.sender == r.flashPool, "callback: wrong pool");

        uint256 owedFee = r.flashWbnbIsToken0 ? fee0 : fee1;

        // ---- 1. Sell WBNB -> USDT on the HIGH-mid pool (the same flash pool,
        //         going through the canonical SwapRouter using its fee tier).
        IERC20(BSC.WBNB).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        uint256 usdtOut = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.WBNB,
                tokenOut: BSC.USDT,
                fee: r.flashFeeTier,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: FLASH_NOTIONAL_WBNB,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        require(usdtOut > 0, "pcsv3 high: zero out");

        // ---- 2. Buy WBNB back on the LOW-mid pool (different fee tier).
        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        uint256 wbnbBack = IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.WBNB,
                fee: r.swapFeeTier,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: usdtOut,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        require(wbnbBack > 0, "pcsv3 low: zero out");

        // ---- 3. Repay flash to the high-mid pool ----
        IERC20(BSC.WBNB).transfer(r.flashPool, FLASH_NOTIONAL_WBNB + owedFee);
    }

    // ---- helpers ----

    function _midOf(address pool) internal view returns (uint256) {
        // Returns USDT per WBNB (1e18). Both tokens are 18-dec.
        IPancakeV3Pool p = IPancakeV3Pool(pool);
        (uint160 sqrtP, , , , , , ) = p.slot0();
        uint256 raw = _sqrtPriceToPriceE18(sqrtP); // token1 per token0
        address t0 = p.token0();
        // If WBNB is token0, raw already = USDT/WBNB.
        return t0 == BSC.WBNB ? raw : (1e36 / raw);
    }

    function _wbnbIsToken0(address pool) internal view returns (bool) {
        return IPancakeV3Pool(pool).token0() == BSC.WBNB;
    }

    function _pickBestPair(uint256 m100, uint256 m500, uint256 m2500)
        internal
        pure
        returns (address highPool, uint24 highFee, address lowPool, uint24 lowFee, uint256 spreadBps)
    {
        // Enumerate the three ordered pairs and pick the largest |spread|.
        address[3] memory pools = [PCS_V3_WBNB_USDT_100, PCS_V3_WBNB_USDT_500, PCS_V3_WBNB_USDT_2500];
        uint24[3] memory fees = [FEE_100, FEE_500, FEE_2500];
        uint256[3] memory mids = [m100, m500, m2500];

        uint256 bestBps = 0;
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3; j++) {
                if (i == j) continue;
                if (mids[i] <= mids[j]) continue;
                uint256 bps = ((mids[i] - mids[j]) * 10_000) / mids[j];
                if (bps > bestBps) {
                    bestBps = bps;
                    highPool = pools[i];
                    highFee  = fees[i];
                    lowPool  = pools[j];
                    lowFee   = fees[j];
                }
            }
        }
        spreadBps = bestBps;
    }

    function _sqrtPriceToPriceE18(uint160 sqrtP) internal pure returns (uint256) {
        uint256 num = uint256(sqrtP) * uint256(sqrtP);
        return (num * 1e18) >> 192;
    }
}
