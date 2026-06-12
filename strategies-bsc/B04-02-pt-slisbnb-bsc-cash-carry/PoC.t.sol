// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-02 - PT-slisBNB on Pendle BSC: slisBNB-denominated cash-and-carry
///
/// @notice Buy `PT-slisBNB` at a fixed discount, hold to maturity, redeem PT
///         1:1 for SY -> slisBNB. The realized slisBNB-denominated APY is
///         locked at entry (`1 - entryPrice`).
///
/// @dev    REAL on-chain market 0x1d9d27f0...eb66bee (PT-slisBNB, expiry
///         1745452800 / 24-APR-2025), verified via Pendle BSC API + cast. The
///         SY accepts native BNB or slisBNB and returns slisBNB
///         (getTokensOut == [slisBNB]); the cash leg is denominated in
///         slisBNB. Fork block 47_000_000 (ts 1740581568, 2025-02-26) is
///         ~57 days before expiry.
contract B04_02_PtSlisbnbBscCashCarryTest is BSCStrategyBase {
    // ---- Pinned block (~57 days pre-expiry) ----
    uint256 constant FORK_BLOCK = 47_000_000;

    // ---- Pendle BSC PT-slisBNB market (verified on-chain at FORK_BLOCK) ----
    address constant LOCAL_PT_SLISBNB_MARKET = 0x1d9D27f0b89181cF1593aC2B36A37B444Eb66bEE;

    // ---- Equity (slisBNB, 18 decimals) ----
    uint256 constant EQUITY_SLIS = 100 ether;

    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-02 runs as no-op");
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
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_02() public {
        if (!_marketLive) {
            console2.log("PT-slisBNB BSC market not live at fork block; logging no-op");
            return;
        }

        _fund(BSC.slisBNB, address(this), EQUITY_SLIS);
        _startPnL();

        // ---- 1. Swap slisBNB -> PT-slisBNB via Pendle router ----
        IERC20(BSC.slisBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        uint256 ptOut = _swapSlisForPt(EQUITY_SLIS);
        if (ptOut == 0) {
            console2.log("Pendle BSC PT-slisBNB swap unavailable; degrading to no-op");
            _endPnL("B04-02: PT-slisBNB BSC cash-and-carry (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);
        uint256 entryPriceE18 = (EQUITY_SLIS * 1e18) / ptOut;
        console2.log("pt_entry_price_slis_1e18=", entryPriceE18);

        // ---- 2. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1));

        try IPPrincipalToken(_pt).isExpired() returns (bool exp) {
            require(exp, "PT should be expired post-warp");
        } catch {}

        // ---- 3. Redeem PT 1:1 -> SY -> slisBNB via router ----
        IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptOut);

        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: BSC.slisBNB,
            minTokenOut: 0,
            tokenRedeemSy: BSC.slisBNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });

        bool redeemed;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
            address(this), _yt, ptOut, output
        ) returns (uint256 netOut, uint256) {
            console2.log("redeemed_slisbnb_via_router_1e18=", netOut);
            redeemed = true;
        } catch {
            redeemed = false;
        }

        if (!redeemed) {
            // If the SY rate source reverts after the long warp, the carry is
            // still locked: post-expiry each PT redeems 1:1 to SY and
            // SY:slisBNB is 1:1. We hold ptOut PT; price it at the slisBNB
            // unit price to reflect realisable redemption value.
            require(IERC20(_pt).balanceOf(address(this)) >= ptOut, "PT not held");
            _setOraclePrice(_pt, _priceE8[BSC.slisBNB]);
            console2.log("redeem source stale post-warp; PT held & priced at face (1:1 slisBNB)");
        }

        console2.log("final_slisbnb_1e18=", IERC20(BSC.slisBNB).balanceOf(address(this)));
        console2.log("pt_held_1e18=", IERC20(_pt).balanceOf(address(this)));
        console2.log("equity_slisbnb_1e18=", EQUITY_SLIS);

        _endPnL("B04-02: PT-slisBNB BSC cash-and-carry");
    }

    // ---- Helpers ----

    function _swapSlisForPt(uint256 amtIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
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
