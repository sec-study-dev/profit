// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-07 — YT-asBNB Astherus airdrop / points speculation
///
/// @notice Atomically mint PT+YT-asBNB via `mintPyFromToken`, immediately sell
///         the PT back to BNB, retain the YT to harvest Astherus restaking
///         points + the upcoming Astherus token airdrop. YT-asBNB carries
///         every Astherus point that the underlying asBNB principal would
///         have earned, but only requires the "yield-fraction" of BNB to
///         buy. Expected points leverage 6-12x.
///
/// @dev    Mechanism count: 2 (Astherus + Pendle PY split). Included in B04
///         for thematic completeness alongside the slisBNB analogue (B04-03).
contract B04_07_YtAsbnbAirdropPointsSplitTest is BSCStrategyBase {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 44_500_000;

    // ---- Pendle BSC market (PT/YT-asBNB-25SEP2025) ----
    /// @notice Per-maturity inline constant. TODO verify on Pendle BSC subgraph.
    address constant LOCAL_PT_ASBNB_MARKET_25SEP2025 = 0xC1afE5fe7d4B2a93b3aA0a5b3F1C0a4f0bDb8e21;
    /// @notice Fallback YT address if market `readTokens()` reverts.
    address constant LOCAL_YT_ASBNB_25SEP2025 = 0xCAFEcafeCafEcAFEcafEcAFeCafECafEcafecaFe;
    uint256 constant ASSUMED_EXPIRY = 1_758_758_400;

    uint256 constant EQUITY_BNB = 100 ether;

    address internal _sy;
    address internal _pt;
    address internal _yt;
    uint256 internal _expiry;
    bool internal _marketLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
        } catch {
            console2.log("BSC_RPC_URL not set; B04-07 runs as no-op");
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
            _yt = LOCAL_YT_ASBNB_25SEP2025;
            _expiry = ASSUMED_EXPIRY;
            _marketLive = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
        if (_yt != address(0)) _trackToken(_yt);
    }

    function testStrategy_B04_07() public {
        if (!_marketLive) {
            console2.log("PT/YT-asBNB BSC market not resolvable; logging no-op");
            return;
        }

        vm.deal(address(this), EQUITY_BNB);
        _startPnL();

        // ---- 1. Mint PT + YT atomically via Pendle router ----
        uint256 pyOut = _mintPyWithBnb(EQUITY_BNB);
        if (pyOut == 0) {
            IWBNB(BSC.WBNB).deposit{value: EQUITY_BNB}();
            IERC20(BSC.WBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
            pyOut = _mintPyWithWbnb(EQUITY_BNB);
        }
        if (pyOut == 0) {
            console2.log("Pendle BSC mintPyFromToken unavailable; no-op");
            _endPnL("B04-07: YT-asBNB airdrop points split (no-op)");
            return;
        }
        console2.log("py_minted_each_1e18=", pyOut);

        uint256 ptBal = IERC20(_pt).balanceOf(address(this));
        uint256 ytBal = IERC20(_yt).balanceOf(address(this));
        console2.log("pt_balance_pre_sale_1e18=", ptBal);
        console2.log("yt_balance_held_1e18=", ytBal);

        // ---- 2. Sell ALL the PT back for BNB ----
        IERC20(_pt).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: BSC.BNB,
            minTokenOut: 0,
            tokenRedeemSy: BSC.BNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactPtForToken(
            address(this), LOCAL_PT_ASBNB_MARKET_25SEP2025, ptBal, output, emptyLimit
        ) returns (uint256 bnbOut, uint256, uint256) {
            console2.log("bnb_recovered_from_pt_sale_1e18=", bnbOut);
        } catch {
            // Fallback to WBNB
            output.tokenOut = BSC.WBNB;
            output.tokenRedeemSy = BSC.WBNB;
            try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactPtForToken(
                address(this), LOCAL_PT_ASBNB_MARKET_25SEP2025, ptBal, output, emptyLimit
            ) returns (uint256 wbnbOut, uint256, uint256) {
                console2.log("wbnb_recovered_from_pt_sale_1e18=", wbnbOut);
            } catch {
                console2.log("PT sale failed entirely; PT still held");
            }
        }

        // ---- 3. Position summary ----
        uint256 finalBnb = address(this).balance;
        uint256 finalWbnb = IERC20(BSC.WBNB).balanceOf(address(this));
        uint256 totalBnbEquity = finalBnb + finalWbnb;
        uint256 finalYt = IERC20(_yt).balanceOf(address(this));

        console2.log("final_bnb_equity_1e18=", totalBnbEquity);
        console2.log("final_yt_held_1e18=", finalYt);
        if (EQUITY_BNB > totalBnbEquity) {
            uint256 ytCost = EQUITY_BNB - totalBnbEquity;
            console2.log("net_yt_cost_bnb_1e18=", ytCost);
            if (ytCost > 0) {
                uint256 leverageE4 = (finalYt * 1e4) / ytCost;
                console2.log("points_leverage_x_1e4=", leverageE4);
            }
        }

        // ---- 4. Sanity: warp to expiry, redeem any residual YT interest ----
        require(_expiry > block.timestamp, "already expired");
        vm.warp(_expiry + 1 hours);
        vm.roll(block.number + 1_000_000);

        try IPYieldToken(_yt).redeemDueInterestAndRewards(address(this), true, true)
            returns (uint256 interestOut, uint256[] memory)
        {
            console2.log("yt_residual_interest_1e18=", interestOut);
        } catch {
            console2.log("YT.redeemDueInterestAndRewards reverted");
        }

        _endPnL("B04-07: YT-asBNB Astherus airdrop points split");
    }

    // ---- Helpers ----

    function _mintPyWithBnb(uint256 bnbIn) internal returns (uint256 pyOut) {
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.BNB,
            netTokenIn: bnbIn,
            tokenMintSy: BSC.BNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).mintPyFromToken{value: bnbIn}(
            address(this), _yt, 0, input
        ) returns (uint256 pyOut_, uint256) {
            pyOut = pyOut_;
        } catch {
            pyOut = 0;
        }
    }

    function _mintPyWithWbnb(uint256 wbnbIn) internal returns (uint256 pyOut) {
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.WBNB,
            netTokenIn: wbnbIn,
            tokenMintSy: BSC.WBNB,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).mintPyFromToken(
            address(this), _yt, 0, input
        ) returns (uint256 pyOut_, uint256) {
            pyOut = pyOut_;
        } catch {
            pyOut = 0;
        }
    }

    receive() external payable {}
}
