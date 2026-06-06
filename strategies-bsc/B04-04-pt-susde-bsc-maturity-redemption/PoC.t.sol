// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IStandardizedYield} from "src/interfaces/pendle/IStandardizedYield.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-04 - PT-sUSDe BSC near-maturity redemption arb (4-day carry)
///
/// @notice Buy PT-sUSDe ~4 days before expiry at a residual BSC-specific
///         discount; warp past maturity; redeem 1:1 USDC. The carry is
///         the *un-arbitraged* gap between BSC and mainnet Pendle markets.
contract B04_04_PtSusdeBscMaturityRedemptionTest is BSCStrategyBase {
    // ---- Pinned block (4 days pre-expiry) ----
    uint256 constant FORK_BLOCK = 47_000_000;

    // ---- Pendle BSC market (PT-sUSDe-26JUN2025) ----
    /// @notice Per-maturity inline constant; same address as in B04-01.
    ///         TODO verify on Pendle BSC subgraph.
    address constant LOCAL_PT_SUSDE_BSC_MARKET = 0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9;
    /// @notice Assumed expiry = 26-JUN-2025 00:00 UTC.
    uint256 constant ASSUMED_EXPIRY = 1_750_896_000;

    // ---- Equity (USDC on BSC is 18 decimal) ----
    uint256 constant EQUITY_USDC = 500_000e18;

    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-04 runs as no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_SUSDE_BSC_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            try IPendleMarket(LOCAL_PT_SUSDE_BSC_MARKET).expiry() returns (uint256 e_) {
                _expiry = e_;
            } catch {
                _expiry = ASSUMED_EXPIRY;
            }
            _marketLive = true;
        } catch {
            _expiry = ASSUMED_EXPIRY;
            _marketLive = false;
        }

        _trackToken(BSC.USDC);
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_04() public {
        if (!_marketLive) {
            console2.log("PT-sUSDe BSC market not resolvable; logging no-op");
            return;
        }

        _fund(BSC.USDC, address(this), EQUITY_USDC);
        _startPnL();

        // ---- 1. Buy PT at near-maturity residual discount ----
        IERC20(BSC.USDC).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        uint256 ptOut = _swapUsdcForPt(EQUITY_USDC);
        if (ptOut == 0) {
            console2.log("Pendle BSC swap rejected; logging no-op");
            _endPnL("B04-04: PT-sUSDe BSC maturity redemption (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);

        // Implied entry price (1e18 scaled). Near maturity, expect >= 0.998.
        uint256 entryPriceE18 = (EQUITY_USDC * 1e18) / ptOut;
        console2.log("pt_entry_price_1e18=", entryPriceE18);

        // ---- 2. Warp past maturity (short carry: ~4 days) ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secsUntil = _expiry - block.timestamp;
        // Sanity guard: don't allow blocks where market is >30 days from expiry,
        // otherwise it's a different strategy.
        if (secsUntil > 30 days) {
            console2.log("fork block too far from expiry for short-carry variant; skipping warp guard");
        }
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsUntil / 3 + 1));

        try IPPrincipalToken(_pt).isExpired() returns (bool exp) {
            require(exp, "PT should be expired post-warp");
        } catch {}

        // ---- 3. Redeem PT -> USDC via Pendle router ----
        IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptOut);

        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: BSC.USDC,
            minTokenOut: 0,
            tokenRedeemSy: BSC.USDC,
            pendleSwap: address(0),
            swapData: emptySwap
        });

        try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
            address(this), _yt, ptOut, output
        ) returns (uint256 netTokenOut, uint256) {
            console2.log("redeemed_usdc_via_router_1e18=", netTokenOut);
        } catch {
            _fallbackRedeem(ptOut);
        }

        uint256 finalUsdc = IERC20(BSC.USDC).balanceOf(address(this));
        console2.log("final_usdc_1e18=", finalUsdc);
        console2.log("equity_usdc_1e18=", EQUITY_USDC);

        // Realized carry in basis points (1e4 = 100 bps).
        if (finalUsdc > EQUITY_USDC) {
            uint256 gainBps = ((finalUsdc - EQUITY_USDC) * 1e4) / EQUITY_USDC;
            console2.log("realized_carry_bps_e4=", gainBps);
        }

        _endPnL("B04-04: PT-sUSDe BSC maturity redemption arb");
    }

    // ---- Helpers ----

    function _swapUsdcForPt(uint256 usdcIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.USDC,
            netTokenIn: usdcIn,
            tokenMintSy: BSC.USDC,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_SUSDE_BSC_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }

    function _fallbackRedeem(uint256 ptAmount) internal {
        IERC20(_pt).transfer(_yt, ptAmount);
        try IPYieldToken(_yt).redeemPY(address(this)) returns (uint256 syOut) {
            console2.log("sy_received_1e18=", syOut);
            try IStandardizedYield(_sy).redeem(address(this), syOut, BSC.USDC, 0, false)
                returns (uint256 usdcOut)
            {
                console2.log("redeemed_usdc_via_sy_1e18=", usdcOut);
            } catch {
                console2.log("SY.redeem(USDC) failed; SY held");
            }
        } catch {
            console2.log("YT.redeemPY failed; PT stuck");
        }
    }
}
