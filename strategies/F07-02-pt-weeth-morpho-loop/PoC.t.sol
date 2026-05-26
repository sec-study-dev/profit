// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @title F07-02 - PT-weETH leveraged buy on Morpho (ETH-side carry)
///
/// @notice ETH-side analogue of F07-01: discounted PT-weETH posted to Morpho
///         PT-weETH/WETH market, lever up with WETH borrows, capture implied
///         ETH-staking APY * leverage minus WETH borrow rate.
contract F07_02_PtWeethMorphoLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Mid-August 2024. PT-weETH-26DEC2024 has ~4.5 months to maturity;
    ///      Morpho PT-weETH/WETH market live and liquid.
    uint256 constant FORK_BLOCK = 20_650_000;

    // ---- Pendle market (maturity-specific) ----
    /// @dev Pendle Market for PT/YT/SY-weETH-26DEC2024.
    ///      Source: Pendle markets registry (weETH 26-Dec-2024).
    address constant LOCAL_MARKET = 0x7d372819240D14fB477f17b964f95F33BeB4c704;

    // ---- Morpho market (PT-weETH-26DEC2024 / WETH) ----
    /// @dev Gauntlet-deployed PendleSparkLinearDiscount oracle, PT-weETH-26DEC24 / WETH.
    address constant MORPHO_ORACLE_PT_WEETH = 0xb4d18ea791f65C0A4Ec06f8aCF8e8e1C2Eeca35d;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @dev 86% LLTV variant for PT-weETH/WETH market.
    uint256 constant LLTV_86 = 0.86e18;

    // ---- Loop tuning ----
    uint256 constant EQUITY_WETH = 100 ether;
    uint256 constant LOOPS = 4;
    uint256 constant LOOP_LTV_BPS = 8200; // 82% per loop (safety under 86% LLTV)

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(_pt);
        _trackToken(_sy);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: _pt,
            oracle: MORPHO_ORACLE_PT_WEETH,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });
    }

    function testStrategy_F07_02() public {
        _fund(Mainnet.WETH, address(this), EQUITY_WETH);
        _startPnL();

        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        // ---- 1. Initial PT buy ----
        _swapWethForPt(EQUITY_WETH, 0);

        // ---- 2. Loop ----
        for (uint256 i = 0; i < LOOPS; i++) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(
                _market, IERC20(_pt).balanceOf(address(this)), address(this), ""
            );

            // Estimate borrowable amount: assume PT priced ~0.965 WETH/PT (18 dec
            // each). Pricing is implemented by Morpho's oracle; for PoC we use
            // a static approximation. For live use, query oracle.price().
            uint256 collTotal = _getCollateral();
            uint256 collValueWeth = (collTotal * 965) / 1000;
            uint256 wantDebt = (collValueWeth * LOOP_LTV_BPS) / 10_000;
            uint256 already = _getBorrowedAssets();
            if (wantDebt <= already) break;
            uint256 toBorrow = wantDebt - already;
            if (toBorrow < 0.01 ether) break;

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrow, 0, address(this), address(this));
            _swapWethForPt(toBorrow, 0);
        }

        // Final supply to lock leverage.
        uint256 trailing = IERC20(_pt).balanceOf(address(this));
        if (trailing > 0) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, trailing, address(this), "");
        }

        emit log_named_uint("pt_collateral_1e18", _getCollateral());
        emit log_named_uint("weth_debt_1e18", _getBorrowedAssets());
        emit log_named_uint("equity_weth_1e18", EQUITY_WETH);

        _endPnL("F07-02: PT-weETH leveraged on Morpho");
    }

    // ---- Helpers ----

    function _swapWethForPt(uint256 wethIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethIn,
            tokenMintSy: Mainnet.WETH, // SY-weETH accepts WETH, ETH, eETH, weETH
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
