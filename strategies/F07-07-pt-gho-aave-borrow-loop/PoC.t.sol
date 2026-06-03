// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F07-07 - PT-sUSDe-26DEC2024 leveraged loop on Morpho with USDC debt
///
/// @notice Buys discounted PT-sUSDe-26DEC2024 via Pendle, posts as collateral on
///         Morpho's PT-sUSDe-26DEC2024/USDC 91.5% LLTV market, borrows USDC,
///         buys more PT, loops. Captures (PT_apy - USDC_borrow_cost) * leverage.
///
///         NOTE: the original design targeted a PT-sUSDe/GHO Morpho market which
///         does NOT exist on-chain. Retargeted to the PT-sUSDe-26DEC2024/USDC
///         91.5% LLTV market (id 0xd8cb35...) which is verified live at this block.
///         USDC->USDe conversion via Curve is required since SY-sUSDe-26DEC2024
///         only accepts USDe and sUSDe as tokenMintSy.
contract F07_07_PtGhoAaveBorrowLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Late Oct 2024. PT-sUSDe-26DEC2024 has ~2 months to maturity;
    ///      PT-sUSDe-26DEC2024/USDC Morpho market live.
    uint256 constant FORK_BLOCK = 21_000_000;

    // ---- Pendle market (PT/YT/SY-sUSDe-26DEC2024) ----
    /// @dev Pendle Market for PT/YT/SY-sUSDe - maturity 26-DEC-2024.
    ///      SY-sUSDe-26DEC2024 accepts: USDe, sUSDe.
    address constant LOCAL_MARKET = 0xa0ab94DeBB3cC9A7eA77f3205ba4AB23276feD08;

    /// @dev Curve USDe/USDC pool for USDC->USDe conversion.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    // ---- Morpho market: PT-sUSDe-26DEC2024 / USDC, 91.5% LLTV ----
    /// @dev PendleSparkLinearDiscount oracle for PT-sUSDe-26DEC2024 vs USDC.
    address constant MORPHO_ORACLE_PT_SUSDE_USDC = 0xB35B25ADC53157f4b76a0eECc94EfE915A0AA968;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_91_5 = 0.915e18;

    // ---- Loop tuning ----
    uint256 constant EQUITY_USDC = 100_000e6; // 100k USDC
    uint256 constant LOOPS = 3;
    uint256 constant LOOP_LTV_BPS = 8500; // 85% (buffer under 91.5% LLTV)

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(_pt);
        _trackToken(_sy);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDC,
            collateralToken: _pt,
            oracle: MORPHO_ORACLE_PT_SUSDE_USDC,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_91_5
        });
    }

    function testStrategy_F07_07() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        // ---- 1. Initial PT-sUSDe buy via Pendle V4 ----
        _swapUsdcForPt(EQUITY_USDC, 0);

        // ---- 2. Loop: supply PT -> borrow USDC -> buy more PT ----
        for (uint256 i = 0; i < LOOPS; i++) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(
                _market, IERC20(_pt).balanceOf(address(this)), address(this), ""
            );

            // PT-sUSDe-26DEC2024 priced ~0.97 USDC/PT at ~2 months to maturity.
            uint256 collTotal = _getCollateral();
            uint256 collValueUsdc = (collTotal * 97) / 100 / 1e12;
            uint256 wantDebt = (collValueUsdc * LOOP_LTV_BPS) / 10_000;
            uint256 already = _getBorrowedAssets();
            if (wantDebt <= already) break;
            uint256 toBorrowUsdc = wantDebt - already;
            if (toBorrowUsdc < 1_000e6) break;

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrowUsdc, 0, address(this), address(this));

            // Re-buy PT.
            _swapUsdcForPt(toBorrowUsdc, 0);
        }

        // Final supply.
        uint256 trailing = IERC20(_pt).balanceOf(address(this));
        if (trailing > 0) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, trailing, address(this), "");
        }

        emit log_named_uint("pt_collateral_1e18", _getCollateral());
        emit log_named_uint("usdc_debt_1e6", _getBorrowedAssets());
        emit log_named_uint("equity_usdc_1e6", EQUITY_USDC);

        _endPnL("F07-07: PT-sUSDe-26DEC2024 leveraged on Morpho USDC/PT market");
    }

    // ---- Helpers ----

    function _swapUsdcForPt(uint256 usdcIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        // SY-sUSDe-26DEC2024 only accepts USDe and sUSDe. Convert USDC->USDe via Curve.
        uint256 usdeIn = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), usdcIn, 0
        );

        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDE,
            netTokenIn: usdeIn,
            tokenMintSy: Mainnet.USDE, // SY-sUSDe-26DEC2024 accepts USDe and sUSDe
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_MARKET, minPtOut, approx, input, emptyLimit
        );
    }

    function _marketId() internal view returns (bytes32) {
        return keccak256(abi.encode(_market));
    }

    function _getCollateral() internal view returns (uint256) {
        return IMorpho(Mainnet.MORPHO).position(_marketId(), address(this)).collateral;
    }

    function _getBorrowedAssets() internal view returns (uint256) {
        IMorpho.Position memory p = IMorpho(Mainnet.MORPHO).position(_marketId(), address(this));
        if (p.borrowShares == 0) return 0;
        IMorpho.Market memory m = IMorpho(Mainnet.MORPHO).market(_marketId());
        if (m.totalBorrowShares == 0) return 0;
        return (uint256(p.borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;
    }
}
