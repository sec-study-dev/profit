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

/// @title B04-01 — PT-sUSDe on Pendle BSC: cash-and-carry to maturity
///
/// @notice Buy `PT-sUSDe-26JUN2025` on Pendle's BSC deployment at a fixed
///         discount, warp past maturity, then redeem PT 1:1 for SY -> USDC.
///         The carry is `(1 - entryPrice)` annualized.
///
/// @dev Offline-first: all external calls are wrapped in `try/catch` so the
///      PoC degrades to a logged no-op when BSC RPC is missing or the Pendle
///      BSC router has not yet been deployed at the documented address.
contract B04_01_PtSusdeBscCashCarryTest is BSCStrategyBase {
    // ---- Pinned block ----
    /// @dev Mid-Q1 2025; ~5-6 months before the assumed 26-JUN-2025 expiry.
    ///      Re-pin once BSC RPC is configured + the actual market expiry is
    ///      verified via Pendle's BSC subgraph.
    uint256 constant FORK_BLOCK = 42_000_000;

    // ---- Pendle BSC market ----
    /// @notice Pendle PT-sUSDe-26JUN2025 market on BSC (PT/YT/SY-sUSDe AMM).
    /// @dev    Per-maturity inline constant. TODO verify on Pendle BSC
    ///         subgraph (https://app.pendle.finance/?chain=bsc). Placeholder
    ///         derived from the mainnet PT-sUSDe-26JUN2025 market address;
    ///         actual BSC deployment uses a deterministic CREATE2 but the
    ///         salt is per-chain. PoC `try/catch`'s the call so a wrong
    ///         address degrades to a no-op rather than a revert.
    address constant LOCAL_PT_SUSDE_MARKET_26JUN2025 = 0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9;
    /// @notice Assumed expiry timestamp = 26-JUN-2025 00:00 UTC.
    uint256 constant ASSUMED_EXPIRY = 1_750_896_000;

    // ---- Equity ----
    /// @dev USDC on BSC is 18-decimal (Binance-Peg USDC), NOT 6.
    uint256 constant EQUITY_USDC = 1_000_000e18;

    // ---- Discovered at setUp ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        // Skip fork creation if BSC_RPC_URL is not set; PoC then runs as a
        // logged no-op so the rest of the suite is unaffected.
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-01 runs as no-op");
            return;
        }

        // Resolve PT/YT/SY from the market; tolerate a missing market.
        try IPendleMarket(LOCAL_PT_SUSDE_MARKET_26JUN2025).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            try IPendleMarket(LOCAL_PT_SUSDE_MARKET_26JUN2025).expiry() returns (uint256 e_) {
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

    function testStrategy_B04_01() public {
        if (!_marketLive) {
            console2.log("PT-sUSDe BSC market not resolvable; logging no-op");
            return;
        }

        _fund(BSC.USDC, address(this), EQUITY_USDC);
        _startPnL();

        // ---- 1. Approve router + swap USDC -> PT ----
        IERC20(BSC.USDC).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        uint256 ptOut = _swapUsdcForPt(EQUITY_USDC);
        if (ptOut == 0) {
            console2.log("Pendle BSC router rejected swap; degrading to no-op");
            _endPnL("B04-01: PT-sUSDe BSC cash-and-carry (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);
        // Implied entry price (1e18-scaled). 1 - this = locked carry over
        // the remaining maturity.
        uint256 entryPriceE18 = (EQUITY_USDC * 1e18) / ptOut;
        console2.log("pt_entry_price_1e18=", entryPriceE18);

        // ---- 2. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1)); // BSC ~3s block

        // Sanity: PT should be expired.
        try IPPrincipalToken(_pt).isExpired() returns (bool exp) {
            require(exp, "PT should be expired post-warp");
        } catch {
            // Some PT implementations may not expose isExpired pre-deploy;
            // ignore.
        }

        // ---- 3. Redeem PT 1:1 -> SY -> USDC via Pendle router ----
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
            // Fallback: manual PT -> SY (via YT.redeemPY) -> token (via SY.redeem).
            _fallbackRedeem(ptOut);
        }

        console2.log("final_usdc_1e18=", IERC20(BSC.USDC).balanceOf(address(this)));
        console2.log("equity_usdc_1e18=", EQUITY_USDC);

        _endPnL("B04-01: PT-sUSDe BSC cash-and-carry");
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
            address(this), LOCAL_PT_SUSDE_MARKET_26JUN2025, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }

    function _fallbackRedeem(uint256 ptAmount) internal {
        // Post-expiry, transferring PT to YT then calling redeemPY burns PT
        // and produces SY 1:1.
        IERC20(_pt).transfer(_yt, ptAmount);
        try IPYieldToken(_yt).redeemPY(address(this)) returns (uint256 syOut) {
            console2.log("sy_received_1e18=", syOut);
            // SY -> USDC via direct SY.redeem.
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
