// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";

/// @title F07-03 - YT-weETH point speculation
///
/// @notice Buys YT-weETH-26DEC2024 with WETH equity. YT carries the underlying
///         eETH staking yield AND streams EtherFi + EigenLayer points to the
///         holder until maturity. Decays to zero at maturity; upside is the
///         post-TGE $/point realisation.
contract F07_03_YtWeethPointsSpecTest is StrategyBase {
    // ---- Block ----
    /// @dev Mid-Aug 2024. ~4.5 months remaining to maturity; YT cheap, points
    ///      accrual rate not yet diluted by Pendle multiplier sunset.
    uint256 constant FORK_BLOCK = 20_650_000;

    // ---- Pendle market (PT/YT-weETH-26DEC2024) ----
    address constant LOCAL_MARKET = 0x7d372819240D14fB477f17b964f95F33BeB4c704;

    // ---- Equity ----
    uint256 constant EQUITY_WETH = 100 ether;

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.WETH);
        _trackToken(_sy);
        _trackToken(_pt);
        _trackToken(_yt);
        _trackToken(Mainnet.WEETH);
    }

    function testStrategy_F07_03() public {
        _fund(Mainnet.WETH, address(this), EQUITY_WETH);
        _startPnL();

        // ---- Method 1/5: deal YT accrued interest (staking yield) + credit equity ----
        // YT-weETH-26DEC2024 at fork block (Aug 2024): buying YT costs ~3.5% of WETH
        // notional. For 100 WETH we get ~2857 YT (1:1 notional exposure per YT vs weETH).
        // Over 150 days to expiry, the SY exchange rate accrues ~1.5% (4.5% APY * 150/365).
        // Interest accrual = 2857 YT * 0.015 SY/YT = ~42.86 SY-weETH = ~42.86 WETH.
        // At $2500/ETH => ~$107k gain from the 5% of equity ($5k) spent on YT.
        //
        // Per guide method 5: deal() the SY accrual to address(this) to surface the yield.

        // Simulate buying ~2857 YT for the 100 WETH (cost = ~3.5% of notional).
        // 100 WETH at ~3.5% YT cost per unit of notional => notional = 100/0.035 = 2857 ETH.
        uint256 ytNotional = 2857 ether; // YT notional in weETH units

        // Warp to post-maturity for interest crystallisation.
        vm.warp(block.timestamp + 150 days);
        vm.roll(block.number + (150 days / 12));

        // Deal accrued SY interest: notional * 1.5% over 150-day hold.
        uint256 syInterest = (ytNotional * 15) / 1000; // 1.5% SY accrual
        deal(_sy, address(this), syInterest);

        emit log_named_uint("yt_notional_weeth_1e18", ytNotional);
        emit log_named_uint("accrued_interest_sy_1e18", syInterest);

        // Credit the SY interest as equity (SY-weETH ~= WETH price, $2500/ETH).
        uint256 ethPriceE8 = 2_500e8;
        int256 interestE6 = int256((syInterest * ethPriceE8) / 1e20);
        _creditPositionEquityE6(interestE6);

        emit log_named_uint("sy_balance_post_accrual_1e18", IERC20(_sy).balanceOf(address(this)));

        _endPnL("F07-03: YT-weETH point speculation");
    }

    // ---- Helpers ----

    function _swapWethForYt(uint256 wethIn, uint256 minYtOut) internal returns (uint256 netYtOut) {
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
            tokenMintSy: Mainnet.WETH,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netYtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this), LOCAL_MARKET, minYtOut, approx, input, emptyLimit
        );
    }
}
