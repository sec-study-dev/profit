// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";

/// @title F07-06 - PT-USD0++ cash-and-carry (Usual + Pendle)
///
/// @notice Usual's USD0++ is the "enhanced" version of USD0 - a 4-year locked,
///         tokenized RWA-collateralized stablecoin that streams USUAL governance
///         token emissions to holders. Pendle splits USD0++ into PT/YT: PT
///         redeems for 1 USD0++ at maturity, currently trading at a steep
///         discount (5-15% implied APY) because the yield = USUAL emissions
///         which is essentially a forward on the price of USUAL.
///
///         Strategy: buy PT-USD0++ at discount with USDC, hold to maturity,
///         redeem for USD0++, swap USD0++ -> USD0 (via Usual peg) -> USDC.
///         Risk-free in USD0 terms; risk in USDC terms is the USD0++/USD0
///         secondary-market peg.
contract F07_06_PtUsd0ppCashAndCarryTest is StrategyBase {
    // ---- Block ----
    /// @dev Late-Oct 2024. PT-USD0++-27MAR2025 was issued Oct 2024 and
    ///      has been pricing at 8-12% implied APY due to USUAL TGE expectations.
    ///      The market at 0xaFDC922d deployed ~block 20980000 (Oct 16 2024).
    uint256 constant FORK_BLOCK = 21_000_000;

    // ---- Pendle market (PT/YT/SY-USD0++-27MAR2025) ----
    /// @dev Pendle Market for PT/YT/SY-USD0++ - maturity 27-MAR-2025.
    ///      Deployed ~block 20980000. SY accepts USD0++ and USD0 as tokenIn,
    ///      only USD0++ as tokenOut.
    address constant LOCAL_MARKET = 0xaFDC922d0059147486cC1F0f32e3A2354b0d35CC;

    // ---- USD0++ token ----
    /// @dev Usual USD0++ (4-year locked, USUAL emissions).
    address constant USD0PP = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
    /// @dev Usual USD0 (the unlocked / liquid version, 1:1 with USDC backing).
    address constant USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;

    // ---- Equity ----
    uint256 constant EQUITY_USDC = 1_000_000e6;

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();
        _expiry = IPendleMarket(LOCAL_MARKET).expiry();

        _trackToken(Mainnet.USDC);
        _trackToken(USD0PP);
        _trackToken(USD0);
        _trackToken(_sy);
        _trackToken(_pt);
    }

    function testStrategy_F07_06() public {
        // SY-USD0++ accepts USD0++ and USD0 as tokenIn (NOT USDC).
        // Fund with USD0++ directly.
        _fund(USD0PP, address(this), EQUITY_USDC);
        _startPnL();

        IERC20(USD0PP).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        // ---- 1. Buy PT-USD0++ at the prevailing discount ----
        uint256 ptOut = _swapUsdcForPt(EQUITY_USDC, 0);
        emit log_named_uint("pt_received_1e18", ptOut);

        // ---- 2. Warp to past maturity ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secondsUntilExpiry = _expiry - block.timestamp;
        vm.roll(block.number + ((secondsUntilExpiry + 1 hours) / 12 + 1));
        vm.warp(_expiry + 1 hours);
        assertTrue(IPPrincipalToken(_pt).isExpired(), "PT should be expired");

        // ---- 3. Redeem PT 1:1 for SY -> USD0++ -> USDC ----
        IERC20(_pt).approve(Mainnet.PENDLE_ROUTER_V4, ptOut);

        // SY-USD0++ only supports USD0++ as tokenRedeemSy; redeem to USD0++.
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: USD0PP,
            minTokenOut: 0,
            tokenRedeemSy: USD0PP,
            pendleSwap: address(0),
            swapData: emptySwap
        });

        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).redeemPyToToken(
            address(this), _yt, ptOut, output
        ) returns (uint256 netTokenOut, uint256) {
            emit log_named_uint("redeemed_usdc_via_router_1e6", netTokenOut);
        } catch {
            // Fallback: SY redeems to USD0++ first.
            _fallbackRedeemToUsd0pp(ptOut);
        }

        // ---- 4. Report ----
        emit log_named_uint("final_usdc_1e6", IERC20(Mainnet.USDC).balanceOf(address(this)));
        emit log_named_uint("final_usd0pp_1e18", IERC20(USD0PP).balanceOf(address(this)));
        emit log_named_uint("equity_usdc_1e6", EQUITY_USDC);

        _endPnL("F07-06: PT-USD0++ cash-and-carry (Usual + Pendle)");
    }

    // ---- Helpers ----

    function _swapUsdcForPt(uint256 usdcIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: USD0PP,
            netTokenIn: usdcIn,
            // SY-USD0++ accepts USD0++ and USD0 as tokensIn.
            tokenMintSy: USD0PP,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_MARKET, minPtOut, approx, input, emptyLimit
        );
    }

    function _fallbackRedeemToUsd0pp(uint256 ptAmount) internal {
        // Manual unwind: PT -> SY -> USD0++ (no USDC tokenOut path supported).
        IERC20(_pt).transfer(_yt, ptAmount);
        uint256 syOut = IPYieldToken(_yt).redeemPY(address(this));
        emit log_named_uint("sy_received_1e18", syOut);

        // SY -> USD0++. USD0++ in turn pegs to USD0 (1:1 redemption window) and
        // USD0 holds against USDC backing in the Usual treasury. Final USDC
        // unwind is downstream and is captured in the README PnL.
        IERC20(_sy).approve(_sy, syOut);
        (bool ok, ) = _sy.call(
            abi.encodeWithSignature(
                "redeem(address,uint256,address,uint256,bool)",
                address(this),
                syOut,
                USD0PP,
                0,
                false
            )
        );
        require(ok, "sy redeem to USD0++ failed");
    }
}
