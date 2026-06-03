// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @notice Minimal Curve StableSwap interface for USDe/USDC pool.
interface ICurveStableSwap {
    /// @dev exchange(i, j, dx, min_dy): swap dx of coin[i] for coin[j].
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

/// @title F07-07 - PT-sUSDe collateral on Morpho, USDC debt + Curve loop (3-mech)
///
/// @notice 3-mechanism stack:
///         1. Pendle PT-sUSDe-26DEC2024 - fixed-discount USDe-yield zero-coupon.
///         2. Morpho Blue PT-sUSDe/USDC market - real on-chain market (Gauntlet
///            curated, 91.5% LLTV, PendleSparkLinearDiscount oracle).
///         3. Curve USDe/USDC stable pool - swap borrowed USDC back to USDe
///            (the SY-accepted token) for the PT re-buy loop.
///
///         Strategy: fund sUSDe -> buy PT-sUSDe with sUSDe via Pendle V4 ->
///         supply PT as Morpho collateral -> borrow USDC -> swap USDC->USDe
///         via Curve -> buy more PT -> loop. Captures (PT_apy - USDC_borrow)
///         * leverage, with SY tokenIn constraint handled by Curve USDe<->USDC.
///
///         Note: the GHO/PT-sUSDe Morpho market referenced in the original
///         strategy design was not deployed at any surveyed fork block; the
///         real production market is USDC/PT-sUSDe at Morpho market id
///         0xd8cb3574...
contract F07_07_PtGhoAaveBorrowLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Dec 7 2024. PT-sUSDe-26DEC2024 has ~19 days to maturity; Morpho
    ///      PT-sUSDe/USDC market live (created ~block 21340000).
    uint256 constant FORK_BLOCK = 21_350_000;

    // ---- Pendle market (PT/YT/SY-sUSDe-26DEC2024) ----
    /// @dev Pendle Market for PT/YT/SY-sUSDe - maturity 26-DEC-2024.
    ///      SY-sUSDe accepts USDe (0x4c9EDD...) and sUSDe (0x9D39A5...) as
    ///      tokenIn. Does NOT accept USDC.
    address constant LOCAL_MARKET = 0xa0ab94DeBB3cC9A7eA77f3205ba4AB23276feD08;

    // ---- Morpho market: PT-sUSDe-26DEC2024 / USDC, 91.5% LLTV ----
    /// @dev Real Morpho marketId for USDC/PT-sUSDe-26DEC2024.
    ///      Loan: USDC, Collateral: PT-sUSDe-26DEC2024
    ///      Oracle: 0xB35B25ADC53157f4b76a0eECc94EfE915A0AA968 (PendleSparkLinear)
    ///      IRM: AdaptiveCurve, LLTV: 91.5%
    bytes32 constant MORPHO_MARKET_ID =
        0xd8cb3574ec8bc5b4dcec68f87dd3a57c4ed73b0f2dc712da212f8198eb93dc1f;

    // ---- Curve USDe/USDC stable pool ----
    /// @dev coin0 = USDe (18-dec), coin1 = USDC (6-dec).
    address constant CURVE_USDE_USDC_POOL = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    // ---- Loop tuning ----
    /// @dev Fund with sUSDe (accepted by SY-sUSDe).
    uint256 constant EQUITY_SUSDE = 100_000e18;
    uint256 constant LOOPS = 3;
    uint256 constant LOOP_LTV_BPS = 8500;

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDE);
        _trackToken(_pt);
        _trackToken(_sy);

        // Load the real market params from Morpho.
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(MORPHO_MARKET_ID);
        require(_market.loanToken != address(0), "F07-07: market not created");
    }

    function testStrategy_F07_07() public {
        _fund(Mainnet.SUSDE, address(this), EQUITY_SUSDE);
        _startPnL();

        IERC20(Mainnet.SUSDE).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.USDC).approve(CURVE_USDE_USDC_POOL, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        // ---- 1. Initial PT-sUSDe buy via Pendle V4 with sUSDe ----
        _swapSusdeForPt(EQUITY_SUSDE, 0);

        // ---- 2. Loop: supply PT -> borrow USDC -> swap USDC->USDe via Curve -> buy more PT ----
        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 ptBal = IERC20(_pt).balanceOf(address(this));
            if (ptBal == 0) break;
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, ptBal, address(this), "");

            // PT-sUSDe priced ~0.98 USDC at ~19 days to maturity.
            // collateral in 18-dec PT, USDC is 6-dec.
            uint256 collTotal = _getCollateral();
            // Convert PT (18-dec) to USDC (6-dec) value: PT * 0.98 / 1e12
            uint256 collValueUsdc = (collTotal * 98) / (100 * 1e12);
            uint256 wantDebt = (collValueUsdc * LOOP_LTV_BPS) / 10_000;
            uint256 already = _getBorrowedAssets();
            if (wantDebt <= already) break;
            uint256 toBorrowUsdc = wantDebt - already;
            if (toBorrowUsdc < 100e6) break; // min 100 USDC

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrowUsdc, 0, address(this), address(this));

            // Swap USDC -> USDe via Curve stable pool (coin1=USDC, coin0=USDe).
            uint256 usdeOut = _swapUsdcToUsde(toBorrowUsdc);
            if (usdeOut == 0) break;

            // Re-buy PT with USDe (accepted by SY-sUSDe).
            _swapUsdeForPt(usdeOut, 0);
        }

        // Final supply of remaining PT balance.
        uint256 trailing = IERC20(_pt).balanceOf(address(this));
        if (trailing > 0) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, trailing, address(this), "");
        }

        emit log_named_uint("pt_collateral_1e18", _getCollateral());
        emit log_named_uint("usdc_debt_1e6", _getBorrowedAssets());
        emit log_named_uint("equity_susde_1e18", EQUITY_SUSDE);

        _endPnL("F07-07: PT-sUSDe collateral + USDC debt (Pendle + Morpho + Curve)");
    }

    // ---- Helpers ----

    function _swapSusdeForPt(uint256 sUsdeIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        // SY-sUSDe accepts sUSDe (0x9D39A5...) as tokenMintSy.
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.SUSDE,
            netTokenIn: sUsdeIn,
            tokenMintSy: Mainnet.SUSDE,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_MARKET, minPtOut, approx, input, emptyLimit
        );
    }

    function _swapUsdeForPt(uint256 usdeIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        // SY-sUSDe also accepts USDe as tokenMintSy.
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDE,
            netTokenIn: usdeIn,
            tokenMintSy: Mainnet.USDE,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_MARKET, minPtOut, approx, input, emptyLimit
        );
    }

    function _swapUsdcToUsde(uint256 usdcIn) internal returns (uint256 usdeOut) {
        // Curve stable pool: coin0=USDe (18-dec), coin1=USDC (6-dec).
        // exchange(1, 0, usdcIn, 0) swaps USDC->USDe.
        usdeOut = ICurveStableSwap(CURVE_USDE_USDC_POOL).exchange(1, 0, usdcIn, 0);
    }

    function _marketId() internal view returns (bytes32) {
        return MORPHO_MARKET_ID;
    }

    function _getCollateral() internal view returns (uint256) {
        return IMorpho(Mainnet.MORPHO).position(MORPHO_MARKET_ID, address(this)).collateral;
    }

    function _getBorrowedAssets() internal view returns (uint256) {
        IMorpho.Position memory p = IMorpho(Mainnet.MORPHO).position(MORPHO_MARKET_ID, address(this));
        if (p.borrowShares == 0) return 0;
        IMorpho.Market memory m = IMorpho(Mainnet.MORPHO).market(MORPHO_MARKET_ID);
        if (m.totalBorrowShares == 0) return 0;
        return (uint256(p.borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;
    }
}
