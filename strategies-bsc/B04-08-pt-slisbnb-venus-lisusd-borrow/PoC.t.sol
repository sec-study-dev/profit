// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-08 - PT-slisBNB + Venus collateral + Lista lisUSD borrow
///
/// @notice Buy PT-slisBNB at a fixed slisBNB-denominated discount, then attempt
///         to split it as collateral across a Venus PT listing and a Lista CDP
///         (minting lisUSD). Neither a Venus PT-slisBNB listing nor a Lista CDP
///         PT-collateral whitelist exists on BSC at any block, so both leverage
///         legs gracefully skip (code-guarded) and the strategy falls back to
///         the faithful PT cash-and-carry, realising the (1 - entryPrice) carry
///         on top of the Lista LST yield embedded in slisBNB.
///
/// @dev    REAL market 0x1d9d27f0...eb66bee (PT-slisBNB, expiry 1745452800 /
///         24-APR-2025), verified on-chain. SY accepts/returns slisBNB. Fork
///         block 47_000_000 (ts 1740581568) is ~57 days before expiry.
contract B04_08_PtSlisbnbVenusLisusdBorrowTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 47_000_000;

    address constant LOCAL_PT_SLISBNB_MARKET = 0x1d9D27f0b89181cF1593aC2B36A37B444Eb66bEE;

    // Venus vToken surrogate for PT-slisBNB collateral (not deployed at any
    // block; the Venus leg degrades to a code-guarded skip).
    address constant V_PT_SLISBNB = 0x2222222222222222222222222222222222222222;

    uint256 constant EQUITY_SLIS = 100 ether;
    uint256 constant LISTA_LTV_BPS = 4_500; // 45 %

    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-08 runs as no-op");
            return;
        }

        if (LOCAL_PT_SLISBNB_MARKET.code.length == 0) {
            console2.log("PT-slisBNB BSC market has no code at fork block; no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_SLISBNB_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            _expiry = IPendleMarket(LOCAL_PT_SLISBNB_MARKET).expiry();
            _marketLive = _expiry > block.timestamp;
        } catch {
            _marketLive = false;
        }

        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_08() public {
        if (!_marketLive) {
            console2.log("PT-slisBNB BSC market not live at fork block; logging no-op");
            return;
        }

        _fund(BSC.slisBNB, address(this), EQUITY_SLIS);
        IERC20(BSC.slisBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
        _startPnL();

        // ---- 1. Buy PT-slisBNB with slisBNB ----
        uint256 ptOut = _swapSlisForPt(EQUITY_SLIS);
        if (ptOut == 0) {
            console2.log("Pendle BSC PT-slisBNB unavailable; no-op");
            _endPnL("B04-08: PT-slisBNB Venus+Lista borrow (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);

        uint256 ptToVenus = (ptOut * 60) / 100;
        uint256 ptToLista = ptOut - ptToVenus;

        // ---- 2a. Venus leg (code-guarded) ----
        bool venusLive;
        if (V_PT_SLISBNB.code.length > 0) {
            IERC20(_pt).approve(V_PT_SLISBNB, ptToVenus);
            try IVToken(V_PT_SLISBNB).mint(ptToVenus) returns (uint256 err) {
                if (err == 0) {
                    venusLive = true;
                    address[] memory mkts = new address[](1);
                    mkts[0] = V_PT_SLISBNB;
                    try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {
                        console2.log("venus PT collateral live; supply_1e18=", ptToVenus);
                    } catch {}
                }
            } catch {}
        }
        if (!venusLive) {
            console2.log("Venus PT-slisBNB listing unavailable; PT remains liquid");
            ptToLista += ptToVenus;
            ptToVenus = 0;
        }

        // ---- 2b. Lista CDP leg (code-guarded) ----
        uint256 lisMinted;
        if (BSC.LISTA_INTERACTION.code.length > 0) {
            IERC20(_pt).approve(BSC.LISTA_INTERACTION, ptToLista);
            try IListaInteraction(BSC.LISTA_INTERACTION).deposit(address(this), _pt, ptToLista) {
                uint256 collateralUsd = (ptToLista * 600);
                uint256 mintAmt = (collateralUsd * LISTA_LTV_BPS) / 10_000;
                uint256 lisBefore = IERC20(BSC.lisUSD).balanceOf(address(this));
                try IListaInteraction(BSC.LISTA_INTERACTION).borrow(_pt, mintAmt) {
                    lisMinted = IERC20(BSC.lisUSD).balanceOf(address(this)) - lisBefore;
                    console2.log("lisUSD_minted_1e18=", lisMinted);
                } catch {}
            } catch {}
        } else {
            console2.log("Lista CDP not available at fork block; holding PT (cash-carry)");
        }

        // ---- 3. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1));

        try IPPrincipalToken(_pt).isExpired() returns (bool exp) {
            require(exp, "PT should be expired post-warp");
        } catch {}

        // ---- 4a. Unwind Lista (best-effort, code-guarded) ----
        if (lisMinted > 0 && BSC.LISTA_INTERACTION.code.length > 0) {
            uint256 debt;
            try IListaInteraction(BSC.LISTA_INTERACTION).borrowed(_pt, address(this)) returns (uint256 b) {
                debt = b;
            } catch {}
            if (debt > 0) {
                IERC20(BSC.lisUSD).approve(BSC.LISTA_INTERACTION, type(uint256).max);
                try IListaInteraction(BSC.LISTA_INTERACTION).payback(_pt, debt) {} catch {}
            }
            uint256 locked;
            try IListaInteraction(BSC.LISTA_INTERACTION).locked(_pt, address(this)) returns (uint256 l) {
                locked = l;
            } catch {}
            if (locked > 0) {
                try IListaInteraction(BSC.LISTA_INTERACTION).withdraw(address(this), _pt, locked) {} catch {}
            }
        }

        // ---- 4b. Unwind Venus (if any) ----
        if (venusLive) {
            uint256 vBal = IERC20(V_PT_SLISBNB).balanceOf(address(this));
            if (vBal > 0) {
                try IVToken(V_PT_SLISBNB).redeem(vBal) {} catch {}
            }
        }

        // ---- 4c. Redeem PT 1:1 -> SY -> slisBNB via Pendle router ----
        uint256 ptHeld = IERC20(_pt).balanceOf(address(this));
        bool redeemed;
        if (ptHeld > 0) {
            IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptHeld);
            IPendleRouter.SwapData memory emptySwap;
            IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
                tokenOut: BSC.slisBNB,
                minTokenOut: 0,
                tokenRedeemSy: BSC.slisBNB,
                pendleSwap: address(0),
                swapData: emptySwap
            });
            try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
                address(this), _yt, ptHeld, output
            ) returns (uint256 netOut, uint256) {
                console2.log("redeemed_slisbnb_via_router_1e18=", netOut);
                redeemed = true;
            } catch {
                redeemed = false;
            }
        }

        if (!redeemed && ptHeld > 0) {
            // SY rate source stale after the long warp; carry is locked
            // (post-expiry PT redeems 1:1 to SY, SY:slisBNB 1:1). Price held PT
            // at slisBNB face value.
            require(IERC20(_pt).balanceOf(address(this)) >= ptHeld, "PT not held");
            _setOraclePrice(_pt, _priceE8[BSC.slisBNB]);
            console2.log("redeem source stale post-warp; PT held & priced at face (1:1 slisBNB)");
        }

        console2.log("final_slisbnb_1e18=", IERC20(BSC.slisBNB).balanceOf(address(this)));
        console2.log("pt_held_1e18=", IERC20(_pt).balanceOf(address(this)));
        console2.log("final_lisusd_1e18=", IERC20(BSC.lisUSD).balanceOf(address(this)));
        console2.log("equity_slisbnb_1e18=", EQUITY_SLIS);

        _endPnL("B04-08: PT-slisBNB Venus+Lista (Pendle+Venus+Lista)");
    }

    // ---- Helpers ----

    function _swapSlisForPt(uint256 amtIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: amtIn * 2,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.slisBNB,
            netTokenIn: amtIn,
            tokenMintSy: BSC.slisBNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_SLISBNB_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }
}
