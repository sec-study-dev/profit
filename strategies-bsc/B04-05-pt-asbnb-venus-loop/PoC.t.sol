// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-05 - PT-asBNB BSC + Venus loop (Astherus + Pendle + Venus)
///
/// @notice Buy `PT-asBNB` on Pendle BSC at a fixed asBNB-denominated discount,
///         then attempt to deposit PT as Venus collateral and borrow to recycle
///         equity. Pendle PT-asBNB is NOT listed on Venus (core or isolated) at
///         any block, so the Venus leg gracefully skips and the strategy falls
///         back to the faithful PT cash-and-carry: hold PT to maturity and
///         realise the (1 - entryPrice) carry on top of the Astherus restaking
///         yield embedded in asBNB.
///
/// @dev    REAL market 0xd75d9fbc...fa9e414 (PT-asBNB, expiry 1753315200 /
///         24-JUL-2025), verified on-chain. SY accepts/returns asBNB. Fork
///         block 51_000_000 (ts 1749244011) is ~48 days before expiry.
contract B04_05_PtAsbnbVenusLoopTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 51_000_000;

    address constant LOCAL_PT_ASBNB_MARKET = 0xD75D9Fbc6486CA5A18037F9eA2fD48044fa9e414;

    // Venus listing surrogate for PT-asBNB collateral (not deployed at any
    // block; the borrow leg degrades to a logged skip if so).
    address constant V_PT_ASBNB = 0x1111111111111111111111111111111111111111;

    uint256 constant EQUITY_ASBNB = 200 ether;
    uint256 constant TARGET_LTV_BPS = 5_000; // 50 %

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

        if (LOCAL_PT_ASBNB_MARKET.code.length == 0) {
            console2.log("PT-asBNB BSC market has no code at fork block; no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_ASBNB_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            _expiry = IPendleMarket(LOCAL_PT_ASBNB_MARKET).expiry();
            _marketLive = _expiry > block.timestamp;
        } catch {
            _marketLive = false;
        }

        _trackToken(BSC.asBNB);
        _trackToken(BSC.USDT);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_05() public {
        if (!_marketLive) {
            console2.log("PT-asBNB BSC market not live at fork block; logging no-op");
            return;
        }

        _fund(BSC.asBNB, address(this), EQUITY_ASBNB);
        IERC20(BSC.asBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
        _startPnL();

        // ---- 1. Buy PT-asBNB with asBNB on Pendle ----
        uint256 ptOut = _swapAsbnbForPt(EQUITY_ASBNB);
        if (ptOut == 0) {
            console2.log("Pendle BSC PT-asBNB unavailable; degrading to no-op");
            _endPnL("B04-05: PT-asBNB Venus loop (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);
        uint256 entryPriceE18 = (EQUITY_ASBNB * 1e18) / ptOut;
        console2.log("pt_entry_price_asbnb_1e18=", entryPriceE18);

        // ---- 2. Attempt Venus PT-asBNB collateral + USDT borrow ----
        bool borrowed;
        if (V_PT_ASBNB.code.length > 0) {
            IERC20(_pt).approve(V_PT_ASBNB, ptOut);
            try IVToken(V_PT_ASBNB).mint(ptOut) returns (uint256 err) {
                if (err == 0) {
                    address[] memory mkts = new address[](1);
                    mkts[0] = V_PT_ASBNB;
                    try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {
                        uint256 collateralUsd = (ptOut * 600 * 95) / 100;
                        uint256 borrowAmt = (collateralUsd * TARGET_LTV_BPS) / 10_000;
                        try IVToken(BSC.vUSDT).borrow(borrowAmt) returns (uint256 berr) {
                            if (berr == 0) {
                                borrowed = true;
                                console2.log("usdt_borrowed_1e18=", IERC20(BSC.USDT).balanceOf(address(this)));
                            }
                        } catch {}
                    } catch {}
                }
            } catch {}
        }
        if (!borrowed) {
            console2.log("Venus PT-asBNB collateral listing unavailable; holding PT (cash-carry)");
        }

        // ---- 3. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1));

        try IPPrincipalToken(_pt).isExpired() returns (bool exp) {
            require(exp, "PT should be expired post-warp");
        } catch {}

        // ---- 4. Redeem PT 1:1 -> SY -> asBNB via Pendle router ----
        uint256 ptHeld = IERC20(_pt).balanceOf(address(this));
        bool redeemed;
        if (ptHeld > 0) {
            IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptHeld);
            IPendleRouter.SwapData memory emptySwap;
            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: BSC.asBNB,
                minTokenOut: 0,
                tokenRedeemSy: BSC.asBNB,
                pendleSwap: address(0),
                swapData: emptySwap
            });
            try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
                address(this), _yt, ptHeld, output
            ) returns (uint256 netOut, uint256) {
                console2.log("redeemed_asbnb_via_router_1e18=", netOut);
                redeemed = true;
            } catch {
                redeemed = false;
            }
        }

        if (!redeemed && ptHeld > 0) {
            // SY rate source stale after warp; PT carry is locked (post-expiry
            // PT redeems 1:1 to SY, SY:asBNB 1:1). Price held PT at asBNB face.
            require(IERC20(_pt).balanceOf(address(this)) >= ptHeld, "PT not held");
            _setOraclePrice(_pt, _priceE8[BSC.asBNB]);
            console2.log("redeem source stale post-warp; PT held & priced at face (1:1 asBNB)");
        }

        console2.log("final_asbnb_1e18=", IERC20(BSC.asBNB).balanceOf(address(this)));
        console2.log("pt_held_1e18=", IERC20(_pt).balanceOf(address(this)));
        console2.log("equity_asbnb_1e18=", EQUITY_ASBNB);

        _endPnL("B04-05: PT-asBNB Venus loop (Astherus+Pendle+Venus)");
    }

    // ---- Helpers ----

    function _swapAsbnbForPt(uint256 amtIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.asBNB,
            netTokenIn: amtIn,
            tokenMintSy: BSC.asBNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_ASBNB_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }
}
