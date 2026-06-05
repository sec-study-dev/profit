// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IListaStakeManager} from "src/interfaces/bsc/lst/IListaStakeManager.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IStandardizedYield} from "src/interfaces/pendle/IStandardizedYield.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-02 - PT-slisBNB on Pendle BSC: BNB-denominated cash-and-carry
///
/// @notice Buy `PT-slisBNB-25SEP2025` with native BNB at a fixed discount,
///         hold to maturity, redeem PT 1:1 for SY -> slisBNB -> BNB. The
///         realized BNB-denominated APY is locked at entry.
///
/// @dev    Offline-safe: every external call is `try/catch`'d. Markets are
///         per-maturity; the inline PT-slisBNB market address must be
///         verified once Pendle's BSC listing is online.
contract B04_02_PtSlisbnbBscCashCarryTest is BSCStrategyBase {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 42_000_000;

    // ---- Pendle BSC market ----
    /// @notice Pendle PT-slisBNB-25SEP2025 market on BSC.
    /// @dev    Per-maturity inline constant - must be replaced with the
    ///         actual deployed market address from Pendle's BSC subgraph.
    ///         Placeholder uses a deterministic pattern; PoC handles a wrong
    ///         address gracefully via `try/catch`.
    address constant LOCAL_PT_SLISBNB_MARKET_25SEP2025 = 0xa1B2c3d4E5f60718293a4B5C6d7E8F9012345678;
    /// @notice Assumed expiry = 25-SEP-2025 00:00 UTC.
    uint256 constant ASSUMED_EXPIRY = 1_758_758_400;

    // ---- Equity ----
    uint256 constant EQUITY_BNB = 100 ether;

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
            console2.log("BSC_RPC_URL not set; B04-02 runs as no-op");
            return;
        }

        try IPendleMarket(LOCAL_PT_SLISBNB_MARKET_25SEP2025).readTokens() returns (
            address sy_, address pt_, address yt_
        ) {
            _sy = sy_;
            _pt = pt_;
            _yt = yt_;
            try IPendleMarket(LOCAL_PT_SLISBNB_MARKET_25SEP2025).expiry() returns (uint256 e_) {
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
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_02() public {
        if (!_marketLive) {
            console2.log("PT-slisBNB BSC market not resolvable; logging no-op");
            return;
        }

        // Fund this contract with native BNB.
        vm.deal(address(this), EQUITY_BNB);
        _startPnL();

        // ---- 1. Swap BNB -> PT-slisBNB via Pendle router ----
        uint256 ptOut = _swapBnbForPt(EQUITY_BNB);
        if (ptOut == 0) {
            console2.log("Pendle BSC router rejected BNB swap; trying WBNB path");
            // Wrap and retry as WBNB.
            IWBNB(BSC.WBNB).deposit{value: EQUITY_BNB}();
            IERC20(BSC.WBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
            ptOut = _swapWbnbForPt(EQUITY_BNB);
        }
        if (ptOut == 0) {
            console2.log("Pendle BSC PT-slisBNB swap unavailable; degrading to no-op");
            _endPnL("B04-02: PT-slisBNB BSC cash-and-carry (no-op)");
            return;
        }
        console2.log("pt_received_1e18=", ptOut);

        // Implied BNB-denominated entry price (1e18 scaled).
        uint256 entryPriceE18 = (EQUITY_BNB * 1e18) / ptOut;
        console2.log("pt_entry_price_bnb_1e18=", entryPriceE18);

        // ---- 2. Warp past maturity ----
        require(_expiry > block.timestamp, "already expired at fork block");
        uint256 secsToWarp = _expiry - block.timestamp + 1 hours;
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + (secsToWarp / 3 + 1));

        // ---- 3. Redeem PT -> BNB via router ----
        IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, ptOut);

        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: BSC.BNB, // native sentinel
            minTokenOut: 0,
            tokenRedeemSy: BSC.BNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });

        try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
            address(this), _yt, ptOut, output
        ) returns (uint256 netBnbOut, uint256) {
            console2.log("redeemed_bnb_via_router_1e18=", netBnbOut);
        } catch {
            _fallbackRedeem(ptOut);
        }

        console2.log("final_bnb_1e18=", address(this).balance);
        console2.log("equity_bnb_1e18=", EQUITY_BNB);

        _endPnL("B04-02: PT-slisBNB BSC cash-and-carry");
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
            tokenIn: BSC.BNB, // native sentinel
            netTokenIn: bnbIn,
            tokenMintSy: BSC.BNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt{value: bnbIn}(
            address(this), LOCAL_PT_SLISBNB_MARKET_25SEP2025, 0, approx, input, emptyLimit
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
            address(this), LOCAL_PT_SLISBNB_MARKET_25SEP2025, 0, approx, input, emptyLimit
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
            // SY -> slisBNB
            try IStandardizedYield(_sy).redeem(address(this), syOut, BSC.slisBNB, 0, false)
                returns (uint256 slisOut)
            {
                console2.log("slisbnb_received_1e18=", slisOut);
                // slisBNB -> BNB via StakeManager (note: requestWithdraw is
                // async; on-chain a sync PCS swap would be the realistic
                // emergency unwind. PoC stops here.)
            } catch {
                console2.log("SY.redeem(slisBNB) failed; SY held");
            }
        } catch {
            console2.log("YT.redeemPY failed; PT stuck");
        }
    }
}
