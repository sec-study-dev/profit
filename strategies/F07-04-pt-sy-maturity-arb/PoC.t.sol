// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";

/// @title F07-04 - PT/SY redemption arbitrage near maturity
///
/// @notice Buy PT-sUSDe in the final ~3-5 days at <1.0 SY/PT discount, then
///         warp past maturity and redeem PT 1:1 for SY -> USDC via the Pendle
///         router. Returns the redemption gap (minus Pendle/SY fees).
contract F07_04_PtSyMaturityArbTest is StrategyBase {
    // ---- Block (5 days pre-maturity) ----
    /// @dev ~Jul 20 2024, 5 days before 25-JUL-2024 PT-sUSDe expiry.
    ///      SY-sUSDe-26JUL2024 only accepts USDe as tokenIn/tokenOut.
    uint256 constant FORK_BLOCK = 20_350_000;

    // ---- Pendle market (PT/YT/SY-sUSDe-26JUL2024) ----
    /// @dev Expiry: 1721865600 (Jul 25, 2024). SY only accepts USDe.
    address constant LOCAL_MARKET = 0x19588F29f9402Bb508007FeADd415c875Ee3f19F;

    // ---- Equity (100K USDe; SY-sUSDe only accepts USDe not USDC) ----
    uint256 constant EQUITY_USDE = 100_000e18;

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
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDE);
        _trackToken(_sy);
        _trackToken(_pt);
    }

    function testStrategy_F07_04() public {
        _fund(Mainnet.USDE, address(this), EQUITY_USDE);
        _startPnL();

        IERC20(Mainnet.USDE).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        // ---- 1. Buy PT at near-maturity discount (fund and tokenIn = USDe) ----
        uint256 ptOut = _swapUsdeForPt(EQUITY_USDE, 0);
        emit log_named_uint("pt_received_1e18", ptOut);
        // Implied entry "fixed yield" over the remaining ~4 days is read off
        // the AMM via market.readState; not strictly necessary for PoC PnL.

        // ---- 2. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secondsUntilExpiry = _expiry - block.timestamp;
        vm.roll(block.number + ((secondsUntilExpiry + 1 hours) / 12 + 1));
        vm.warp(_expiry + 1 hours);

        // Confirm expiry status
        assertTrue(IPPrincipalToken(_pt).isExpired(), "PT should be expired");

        // ---- 3. Redeem PT 1:1 for SY, then SY -> USDC via the router ----
        // Approve router to pull PT (and for some paths YT, but post-expiry YT
        // is zero so router will accept PT-only).
        IERC20(_pt).approve(Mainnet.PENDLE_ROUTER_V4, ptOut);

        IPendleRouter.SwapData memory emptySwap;
        // SY-sUSDe-26JUL2024 only supports USDe as tokenRedeemSy.
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: Mainnet.USDE,
            minTokenOut: 0,
            tokenRedeemSy: Mainnet.USDE,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        // redeemPyToToken takes PT+YT in equal amounts; post-expiry YT supply is
        // burnable to zero. Pendle's router exposes a post-expiry path where it
        // accepts PT alone (internally calls YT.redeemPY which only requires PT
        // after expiry). For safety we attempt the redeemPyToToken with the PT
        // balance; if the router requires explicit YT path we fall back to a
        // direct YT.redeemPY + SY.redeem sequence (see _fallbackRedeem).
        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).redeemPyToToken(
            address(this), _yt, ptOut, output
        ) returns (uint256 netTokenOut, uint256) {
            emit log_named_uint("redeemed_usde_via_router_1e18", netTokenOut);
        } catch {
            // Fallback: manual PT -> SY (via YT.redeemPY) -> tokenOut (via SY.redeem).
            _fallbackRedeem(ptOut);
        }

        emit log_named_uint("final_usde_1e18", IERC20(Mainnet.USDE).balanceOf(address(this)));
        emit log_named_uint("equity_usde_1e18", EQUITY_USDE);

        _endPnL("F07-04: PT/SY maturity redemption arb");
    }

    // ---- Helpers ----

    function _swapUsdeForPt(uint256 usdeIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        // SY-sUSDe-26JUL2024 only accepts USDe as tokenIn.
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

    function _fallbackRedeem(uint256 ptAmount) internal {
        // Post-expiry: transfer PT to YT contract, then call redeemPY which
        // burns PT and mints SY 1:1.
        IERC20(_pt).transfer(_yt, ptAmount);
        uint256 syOut = IPYieldToken(_yt).redeemPY(address(this));
        emit log_named_uint("sy_received_1e18", syOut);

        // SY -> USDe. SY-sUSDe-26JUL2024 only accepts USDe as tokenOut.
        IERC20(_sy).approve(_sy, syOut); // SY.redeem(burnFromInternalBalance=false) uses transferFrom
        (bool ok, bytes memory ret) = _sy.call(
            abi.encodeWithSignature(
                "redeem(address,uint256,address,uint256,bool)",
                address(this),
                syOut,
                Mainnet.USDE,
                0,
                false
            )
        );
        require(ok, "sy redeem failed");
        ret;
    }
}
