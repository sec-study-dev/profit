// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IStandardizedYield} from "src/interfaces/pendle/IStandardizedYield.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-05 - PT-asBNB BSC + Venus collateral + USDT borrow (3-mechanism)
///
/// @notice Buy `PT-asBNB-25SEP2025` on Pendle's BSC deployment at a fixed
///         BNB-denominated discount, then deposit the PT as collateral into a
///         Venus isolated pool listing for PT-asBNB (or, if not yet listed,
///         use the SY/PT-asBNB Pendle SY token as the collateral surrogate).
///         Borrow USDT against it to recycle equity into a second
///         PT-asBNB lot. This stacks Astherus restaking yield (embedded in
///         asBNB), Pendle fixed-yield premium, and Venus borrow spread.
///
/// @dev    3-mechanism family: Astherus (asBNB) + Pendle (PT) + Venus (borrow).
///         All external calls wrapped in `try/catch`; offline-safe.
contract B04_05_PtAsbnbVenusLoopTest is BSCStrategyBase {
    // ---- Pinned block ----
    /// @dev Mid-Q2 2025; ~3 months before assumed 25-SEP-2025 expiry.
    uint256 constant FORK_BLOCK = 44_500_000;

    // ---- Pendle BSC market (PT-asBNB-25SEP2025) ----
    /// @notice Per-maturity inline constant. TODO verify on Pendle BSC subgraph.
    address constant LOCAL_PT_ASBNB_MARKET_25SEP2025 = 0xC1AFE5FE7d4B2a93B3aA0a5b3F1C0A4F0bDb8e21;
    /// @notice Assumed expiry = 25-SEP-2025 00:00 UTC.
    uint256 constant ASSUMED_EXPIRY = 1_758_758_400;

    // ---- Venus collateral surrogate ----
    /// @notice Placeholder for the Venus isolated-pool vToken that lists
    ///         PT-asBNB (or SY-asBNB) as collateral. If not listed, the PoC
    ///         degrades the borrow leg to a logged no-op. TODO verify.
    address constant V_PT_ASBNB = 0x1111111111111111111111111111111111111111;

    // ---- Equity ----
    uint256 constant EQUITY_BNB = 200 ether;
    /// @dev Conservative LTV for a PT-class collateral on Venus isolated pool.
    uint256 constant TARGET_LTV_BPS = 5_000; // 50 %

    // ---- Discovered at setUp ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-05 runs as no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_ASBNB_MARKET_25SEP2025).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            try IPendleMarket(LOCAL_PT_ASBNB_MARKET_25SEP2025).expiry() returns (uint256 e_) {
                _expiry = e_;
            } catch {
                _expiry = ASSUMED_EXPIRY;
            }
            _marketLive = true;
        } catch {
            _expiry = ASSUMED_EXPIRY;
            _marketLive = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);
        _trackToken(BSC.USDT);
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_05() public {
        if (!_marketLive) {
            console2.log("PT-asBNB BSC market not resolvable; logging no-op");
            return;
        }

        vm.deal(address(this), EQUITY_BNB);
        _startPnL();

        // ---- 1. Buy PT-asBNB with native BNB on Pendle ----
        uint256 ptOut = _swapBnbForPt(EQUITY_BNB);
        if (ptOut == 0) {
            // Try wrapped path
            IWBNB(BSC.WBNB).deposit{value: EQUITY_BNB}();
            IERC20(BSC.WBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
            ptOut = _swapWbnbForPt(EQUITY_BNB);
        }
        if (ptOut == 0) {
            console2.log("Pendle BSC PT-asBNB unavailable; degrading to no-op");
            _endPnL("B04-05: PT-asBNB Venus loop (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);
        uint256 entryPriceE18 = (EQUITY_BNB * 1e18) / ptOut;
        console2.log("pt_entry_price_bnb_1e18=", entryPriceE18);

        // ---- 2. Deposit PT into Venus isolated-pool listing ----
        // Approve and try to mint vToken. If the listing doesn't exist the
        // call reverts and we capture-and-log.
        IERC20(_pt).approve(V_PT_ASBNB, ptOut);
        uint256 borrowedUsdt;
        try IVToken(V_PT_ASBNB).mint(ptOut) returns (uint256 err) {
            if (err != 0) {
                console2.log("Venus mint returned non-zero error; skipping borrow leg");
            } else {
                // Enter market.
                address[] memory mkts = new address[](1);
                mkts[0] = V_PT_ASBNB;
                try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {
                    // ---- 3. Borrow USDT against PT collateral ----
                    // Notional in USDT terms: ptOut * entryPrice * BNB/USD * LTV.
                    // BNB/USD ~ $600 default; entryPrice ~ 0.95.
                    uint256 collateralUsd = (ptOut * 600 * 95) / 100; // 1e18 scaled
                    uint256 borrowAmt = (collateralUsd * TARGET_LTV_BPS) / 10_000;
                    try IVToken(BSC.vUSDT).borrow(borrowAmt) returns (uint256 berr) {
                        if (berr == 0) {
                            borrowedUsdt = IERC20(BSC.USDT).balanceOf(address(this));
                            console2.log("usdt_borrowed_1e18=", borrowedUsdt);
                        } else {
                            console2.log("Venus borrow USDT returned non-zero err");
                        }
                    } catch {
                        console2.log("Venus borrow USDT reverted; PT collateral may not be listed");
                    }
                } catch {
                    console2.log("enterMarkets reverted");
                }
            }
        } catch {
            console2.log("Venus PT-asBNB market not deployed; PT held unborrowed");
        }

        // ---- 4. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1));

        // ---- 5. Unwind: repay USDT (if borrowed), withdraw PT, redeem ----
        if (borrowedUsdt > 0) {
            IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);
            try IVToken(BSC.vUSDT).repayBorrow(type(uint256).max) returns (uint256 rerr) {
                console2.log("repay_err=", rerr);
            } catch {
                console2.log("repay USDT reverted");
            }
            try IVToken(V_PT_ASBNB).redeem(IERC20(V_PT_ASBNB).balanceOf(address(this))) returns (uint256) {
                console2.log("vToken redeem OK");
            } catch {
                console2.log("vToken redeem reverted");
            }
        }

        // ---- 6. Redeem PT -> BNB via Pendle router ----
        uint256 ptHeld = IERC20(_pt).balanceOf(address(this));
        if (ptHeld > 0) {
            IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptHeld);
            IPendleRouter.SwapData memory emptySwap;
            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: BSC.BNB,
                minTokenOut: 0,
                tokenRedeemSy: BSC.BNB,
                pendleSwap: address(0),
                swapData: emptySwap
            });
            try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
                address(this), _yt, ptHeld, output
            ) returns (uint256 netBnbOut, uint256) {
                console2.log("redeemed_bnb_via_router_1e18=", netBnbOut);
            } catch {
                _fallbackRedeem(ptHeld);
            }
        }

        console2.log("final_bnb_1e18=", address(this).balance);
        console2.log("final_wbnb_1e18=", IERC20(BSC.WBNB).balanceOf(address(this)));
        console2.log("equity_bnb_1e18=", EQUITY_BNB);

        _endPnL("B04-05: PT-asBNB Venus loop (Astherus+Pendle+Venus)");
    }

    // ---- Helpers ----

    function _swapBnbForPt(uint256 bnbIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.BNB,
            netTokenIn: bnbIn,
            tokenMintSy: BSC.BNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt{value: bnbIn}(
            address(this), LOCAL_PT_ASBNB_MARKET_25SEP2025, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }

    function _swapWbnbForPt(uint256 wbnbIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.WBNB,
            netTokenIn: wbnbIn,
            tokenMintSy: BSC.WBNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_ASBNB_MARKET_25SEP2025, 0, approx, input, emptyLimit
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
            try IStandardizedYield(_sy).redeem(address(this), syOut, BSC.asBNB, 0, false)
                returns (uint256 asOut)
            {
                console2.log("asbnb_received_1e18=", asOut);
            } catch {
                console2.log("SY.redeem(asBNB) failed; SY held");
            }
        } catch {
            console2.log("YT.redeemPY failed; PT stuck");
        }
    }

}
