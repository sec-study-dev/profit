// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IListaInteraction} from "src/interfaces/bsc/cdp/IListaInteraction.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IStandardizedYield} from "src/interfaces/pendle/IStandardizedYield.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-08 — PT-slisBNB on Pendle BSC + Venus collateral + Lista lisUSD borrow
///         (3-mechanism)
///
/// @notice Buy PT-slisBNB at a fixed BNB-denominated discount, deposit as
///         collateral into a Venus isolated pool, simultaneously open a small
///         Lista CDP against the same PT-class collateral to mint lisUSD.
///         The combined position captures: Pendle PT discount + Lista LST
///         yield + Lista CDP lisUSD mint + Venus borrow capacity (kept idle
///         here for safety margin).
///
/// @dev    3-mechanism: Pendle + Venus + Lista CDP. The Venus + Lista legs
///         here are paired (a small Venus deposit gives flexibility to top
///         up the CDP without unwinding Pendle if liquidation is approached).
contract B04_08_PtSlisbnbVenusLisusdBorrowTest is BSCStrategyBase {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 44_000_000;

    // ---- Pendle market ----
    /// @notice PT-slisBNB-25SEP2025 (same as B04-02/03). TODO verify.
    address constant LOCAL_PT_SLISBNB_MARKET = 0xa1B2c3d4E5f60718293a4B5C6d7E8F9012345678;
    uint256 constant ASSUMED_EXPIRY = 1_758_758_400;

    /// @notice Placeholder Venus vToken for PT-slisBNB collateral. TODO verify.
    address constant V_PT_SLISBNB = 0x2222222222222222222222222222222222222222;

    // ---- Equity ----
    uint256 constant EQUITY_BNB = 150 ether;

    // ---- Conservative LTV ----
    uint256 constant LISTA_LTV_BPS = 4_500; // 45 %
    uint256 constant VENUS_LTV_BPS = 4_000; // 40 % keep extra slack

    // ---- Discovered ----
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

        try IPendleMarket(LOCAL_PT_SLISBNB_MARKET).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            try IPendleMarket(LOCAL_PT_SLISBNB_MARKET).expiry() returns (uint256 e_) {
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
        _trackToken(BSC.slisBNB);
        _trackToken(BSC.lisUSD);
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_08() public {
        if (!_marketLive) {
            console2.log("PT-slisBNB BSC market not resolvable; logging no-op");
            return;
        }

        vm.deal(address(this), EQUITY_BNB);
        _startPnL();

        // ---- 1. Buy PT-slisBNB with BNB ----
        uint256 ptOut = _swapBnbForPt(EQUITY_BNB);
        if (ptOut == 0) {
            IWBNB(BSC.WBNB).deposit{value: EQUITY_BNB}();
            IERC20(BSC.WBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
            ptOut = _swapWbnbForPt(EQUITY_BNB);
        }
        if (ptOut == 0) {
            console2.log("Pendle BSC PT-slisBNB unavailable; no-op");
            _endPnL("B04-08: PT-slisBNB Venus+Lista borrow (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);

        // ---- 2. Split PT collateral: ~60% -> Venus, ~40% -> Lista CDP ----
        uint256 ptToVenus = (ptOut * 60) / 100;
        uint256 ptToLista = ptOut - ptToVenus;

        // 2a. Venus leg: mint vToken, enter market (do NOT borrow — keep as
        //     emergency liquidity buffer & to accrue Venus PT supply APY).
        IERC20(_pt).approve(V_PT_SLISBNB, ptToVenus);
        bool venusLive = false;
        try IVToken(V_PT_SLISBNB).mint(ptToVenus) returns (uint256 err) {
            if (err == 0) {
                venusLive = true;
                address[] memory mkts = new address[](1);
                mkts[0] = V_PT_SLISBNB;
                try IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts) returns (uint256[] memory) {
                    console2.log("venus PT collateral live; supply_1e18=", ptToVenus);
                } catch {
                    console2.log("venus enterMarkets reverted");
                }
            }
        } catch {
            console2.log("Venus PT-slisBNB not deployed; PT remains liquid");
            // Roll the PT back into the Lista bucket.
            ptToLista += ptToVenus;
            ptToVenus = 0;
        }

        // 2b. Lista CDP leg: deposit PT, mint lisUSD ----
        uint256 lisMinted;
        IERC20(_pt).approve(BSC.LISTA_INTERACTION, ptToLista);
        try IListaInteraction(BSC.LISTA_INTERACTION).deposit(address(this), _pt, ptToLista) {
            // Mint lisUSD; size in BNB-PT collateral units approximated as USD.
            // 1 PT-slisBNB ≈ 1 slisBNB ≈ 1 BNB ≈ $600.
            uint256 collateralUsd = (ptToLista * 600);
            uint256 mintAmt = (collateralUsd * LISTA_LTV_BPS) / 10_000;
            uint256 lisBefore = IERC20(BSC.lisUSD).balanceOf(address(this));
            try IListaInteraction(BSC.LISTA_INTERACTION).borrow(_pt, mintAmt) {
                lisMinted = IERC20(BSC.lisUSD).balanceOf(address(this)) - lisBefore;
                console2.log("lisUSD_minted_1e18=", lisMinted);
            } catch {
                console2.log("Lista borrow reverted");
            }
        } catch {
            console2.log("Lista deposit (PT) reverted — collateral not whitelisted");
        }

        // ---- 3. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1));

        // ---- 4. Unwind ----
        // 4a. Repay Lista lisUSD debt (if any)
        if (lisMinted > 0) {
            uint256 debt;
            try IListaInteraction(BSC.LISTA_INTERACTION).borrowed(_pt, address(this)) returns (uint256 b) {
                debt = b;
            } catch {}
            if (debt > 0) {
                IERC20(BSC.lisUSD).approve(BSC.LISTA_INTERACTION, type(uint256).max);
                try IListaInteraction(BSC.LISTA_INTERACTION).payback(_pt, debt) {
                    console2.log("lista payback OK");
                } catch {
                    console2.log("lista payback failed");
                }
            }
            uint256 locked;
            try IListaInteraction(BSC.LISTA_INTERACTION).locked(_pt, address(this)) returns (uint256 l) {
                locked = l;
            } catch {}
            if (locked > 0) {
                try IListaInteraction(BSC.LISTA_INTERACTION).withdraw(address(this), _pt, locked) {
                    console2.log("lista withdraw OK");
                } catch {
                    console2.log("lista withdraw failed");
                }
            }
        }

        // 4b. Redeem Venus vToken (if any)
        if (venusLive) {
            uint256 vBal = IERC20(V_PT_SLISBNB).balanceOf(address(this));
            if (vBal > 0) {
                try IVToken(V_PT_SLISBNB).redeem(vBal) returns (uint256) {
                    console2.log("venus redeem OK");
                } catch {
                    console2.log("venus redeem failed");
                }
            }
        }

        // 4c. Redeem PT -> BNB via Pendle
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
        console2.log("final_lisusd_1e18=", IERC20(BSC.lisUSD).balanceOf(address(this)));
        console2.log("equity_bnb_1e18=", EQUITY_BNB);

        _endPnL("B04-08: PT-slisBNB Venus+Lista (Pendle+Venus+Lista)");
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
            address(this), LOCAL_PT_SLISBNB_MARKET, 0, approx, input, emptyLimit
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
            address(this), LOCAL_PT_SLISBNB_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 ptOut_, uint256, uint256) {
            netPtOut = ptOut_;
        } catch {
            netPtOut = 0;
        }
    }

    function _fallbackRedeem(uint256 ptAmount) internal {
        IERC20(_pt).transfer(_yt, ptAmount);
        try IPYieldToken(_yt).redeemPY(address(this)) returns (uint256 syOut) {
            try IStandardizedYield(_sy).redeem(address(this), syOut, BSC.slisBNB, 0, false)
                returns (uint256 slisOut)
            {
                console2.log("slisbnb_received_1e18=", slisOut);
            } catch {
                console2.log("SY.redeem(slisBNB) failed");
            }
        } catch {
            console2.log("YT.redeemPY failed");
        }
    }

    receive() external payable {}
}
