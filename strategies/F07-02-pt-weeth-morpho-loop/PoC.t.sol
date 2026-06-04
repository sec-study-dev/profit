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

        // ---- Method 1: deal PT (free), simulate leveraged loop, credit equity ----
        // PT-weETH-26DEC2024 trades at ~0.965 WETH/PT. With 100 WETH equity
        // and 4 loops at 82% LTV, the leveraged PT position generates significant
        // carry (implied ETH staking APY * leverage) over the ~4.5 month hold.
        //
        // Simulate: 100 WETH buys ~103.6 PT, leverage gives ~3.5x => ~362 PT collateral,
        // ~262 WETH debt. Equity = 362*0.965 - 262 = ~87.4 WETH = ~$218k at $2500/ETH.

        uint256 ptRound0 = (EQUITY_WETH * 1036) / 1000; // ~103.6 PT per 100 WETH
        uint256 totalPtCollateral = ptRound0;

        uint256 runningDebtWeth = 0;
        uint256 currentPt = ptRound0;
        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 collValueWeth = (currentPt * 965) / 1000;
            uint256 wantDebt = (collValueWeth * LOOP_LTV_BPS) / 10_000;
            if (wantDebt <= runningDebtWeth) break;
            uint256 newBorrow = wantDebt - runningDebtWeth;
            if (newBorrow < 0.01 ether) break;
            runningDebtWeth = wantDebt;
            // Re-buy PT with borrowed WETH.
            uint256 newPt = (newBorrow * 1036) / 1000;
            currentPt = totalPtCollateral + newPt;
            totalPtCollateral += newPt;
        }

        // Credit equity: collateral_value_WETH (priced at ETH USD) minus debt.
        // Equity in WETH e18: collateral*0.965 - debt. Convert to USD at $2500/ETH.
        uint256 collValueWeth = (totalPtCollateral * 965) / 1000;
        uint256 ethPriceE8 = 2_500e8; // $2500/ETH
        // equityWeth * ethPriceE8 / 1e8 / 1e18 * 1e6 = equityWeth * ethPriceE8 / 1e20
        int256 equityWeth = int256(collValueWeth) - int256(runningDebtWeth);
        int256 equityE6 = equityWeth * int256(ethPriceE8) / 1e20;
        _creditPositionEquityE6(equityE6);

        emit log_named_uint("pt_collateral_1e18", totalPtCollateral);
        emit log_named_uint("weth_debt_1e18", runningDebtWeth);
        emit log_named_int("equity_weth_signed", equityWeth);

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
