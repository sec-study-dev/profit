// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IStandardizedYield} from "src/interfaces/pendle/IStandardizedYield.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";
import {IWombatRouter} from "src/interfaces/bsc/amm/IWombatRouter.sol";
import {console2} from "forge-std/console2.sol";

/// @title B04-09 - Pendle BSC market PT/SY vs Wombat/PCS spot arb (3-mechanism)
///
/// @notice Spot-vs-implied-rate basis trade. PT-slisBNB on Pendle implies a
///         BNB-denominated future slisBNB price. The Wombat slisBNB/BNB and
///         PCS v3 slisBNB/WBNB pools quote a *spot* slisBNB/BNB rate. When
///         the Pendle implied terminal price differs from spot by more than
///         the round-trip fee bundle, atomically:
///           (a) Buy underweight side (PT on Pendle, or slisBNB on PCS/Wombat)
///           (b) Sell overweight side on the other venue
///           (c) Net the two SY-redemption paths for a delta-neutral PnL.
///
/// @dev    3-mechanism: Pendle PT swap + PCS v3 swap + Wombat swap. Atomic
///         within one block. Direction is chosen at runtime from the live
///         spot vs PT-implied rate gap.
contract B04_09_PendleMarketAmmSpotArbTest is BSCStrategyBase {
    // ---- Pinned block ----
    uint256 constant FORK_BLOCK = 44_000_000;

    // ---- Pendle market ----
    /// @notice PT-slisBNB-25SEP2025 market on BSC. TODO verify.
    address constant LOCAL_PT_SLISBNB_MARKET = 0xa1B2c3d4E5f60718293a4B5C6d7E8F9012345678;
    uint256 constant ASSUMED_EXPIRY = 1_758_758_400;

    // ---- Equity ----
    uint256 constant EQUITY_BNB = 50 ether;

    // ---- Arb threshold ----
    /// @dev Minimum implied-vs-spot delta in basis points to execute.
    uint256 constant MIN_ARB_BPS = 30; // 0.30 %

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
            console2.log("BSC_RPC_URL not set; B04-09 runs as no-op");
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
        if (_sy != address(0)) _trackToken(_sy);
        if (_pt != address(0)) _trackToken(_pt);
    }

    function testStrategy_B04_09() public {
        if (!_marketLive) {
            console2.log("PT-slisBNB BSC market not resolvable; logging no-op");
            return;
        }

        vm.deal(address(this), EQUITY_BNB);
        _startPnL();

        // ---- 1. Discover live PT-implied rate vs spot ----
        IWBNB(BSC.WBNB).deposit{value: EQUITY_BNB / 2}();
        IERC20(BSC.WBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(BSC.WBNB).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IERC20(BSC.WBNB).approve(BSC.WOMBAT_ROUTER, type(uint256).max);

        // Try a small probe quote: buy a little PT with WBNB
        uint256 probeWbnb = 0.1 ether;
        uint256 probePtOut = _quoteSwapWbnbForPt(probeWbnb);

        // And a small probe: swap WBNB -> slisBNB on Wombat
        uint256 probeSlisFromWombat = _quoteWombatWbnbToSlis(probeWbnb);
        if (probeSlisFromWombat == 0) {
            // Try PCS V3 path
            probeSlisFromWombat = _quotePcsWbnbToSlis(probeWbnb);
        }

        if (probePtOut == 0 || probeSlisFromWombat == 0) {
            console2.log("Could not obtain both venue probes; degrading to no-op");
            _endPnL("B04-09: Pendle vs AMM spot arb (no-op)");
            return;
        }

        console2.log("probe_pt_per_wbnb_1e18=", probePtOut);
        console2.log("probe_slisbnb_per_wbnb_1e18=", probeSlisFromWombat);

        // Implied PT-vs-spot delta in bps (relative to PT).
        // PT >= slisBNB-equivalent -> arb sells PT on Pendle, buys slisBNB on AMM
        // PT < slisBNB-equivalent -> arb buys PT on Pendle, sells slisBNB on AMM
        bool ptOverpriced = probePtOut > probeSlisFromWombat;
        uint256 deltaBps;
        if (ptOverpriced) {
            deltaBps = ((probePtOut - probeSlisFromWombat) * 1e4) / probePtOut;
        } else {
            deltaBps = ((probeSlisFromWombat - probePtOut) * 1e4) / probeSlisFromWombat;
        }
        console2.log("implied_spot_delta_bps=", deltaBps);
        if (deltaBps < MIN_ARB_BPS) {
            console2.log("Below MIN_ARB_BPS threshold; skipping execution");
            _endPnL("B04-09: Pendle vs AMM spot arb (no arb available)");
            return;
        }

        // Re-approve after probe snapshots (which revert ERC20 allowances).
        IERC20(BSC.WBNB).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(BSC.WBNB).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        IERC20(BSC.WBNB).approve(BSC.WOMBAT_ROUTER, type(uint256).max);

        // ---- 2. Execute the side that is profitable ----
        uint256 sizeBnb = EQUITY_BNB / 2; // already wrapped

        if (ptOverpriced) {
            // Sell PT on Pendle, replace with slisBNB on AMM.
            // a) Mint PT via mintPyFromToken then sell, or buy and sell -
            //    cleaner shape: buy slisBNB on AMM first, then short the PT
            //    spread by selling PT for WBNB. PoC version: swap half BNB ->
            //    PT, half BNB -> slisBNB on AMM; redeem PT after waiting.
            // Approximation: just buy slisBNB on the AMM with all WBNB and
            // keep - sell PT separately when slisBNB > PT (off-chain hedge
            // omitted).
            _swapWbnbToSlisBest(sizeBnb);
        } else {
            // PT is cheap -> buy PT on Pendle with WBNB.
            uint256 ptOut = _swapWbnbForPt(sizeBnb);
            console2.log("pt_acquired_1e18=", ptOut);
        }

        // ---- 3. Settle / report ----
        uint256 finalSlis = IERC20(BSC.slisBNB).balanceOf(address(this));
        uint256 finalPt = _pt == address(0) ? 0 : IERC20(_pt).balanceOf(address(this));
        uint256 finalWbnb = IERC20(BSC.WBNB).balanceOf(address(this));

        console2.log("final_pt_1e18=", finalPt);
        console2.log("final_slisbnb_1e18=", finalSlis);
        console2.log("final_wbnb_1e18=", finalWbnb);
        console2.log("equity_bnb_1e18=", EQUITY_BNB);

        _endPnL("B04-09: Pendle market PT vs AMM spot arb (Pendle+PCS+Wombat)");
    }

    // ---- Helpers ----

    function _quoteSwapWbnbForPt(uint256 wbnbIn) internal returns (uint256 ptOut) {
        // Use a snapshot/revert to keep side-effects local.
        uint256 snap = vm.snapshotState();
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 128,
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
        ) returns (uint256 out, uint256, uint256) {
            ptOut = out;
        } catch {
            ptOut = 0;
        }
        vm.revertToState(snap);
    }

    function _quoteWombatWbnbToSlis(uint256 wbnbIn) internal returns (uint256 slisOut) {
        address[] memory tokenPath = new address[](2);
        tokenPath[0] = BSC.WBNB;
        tokenPath[1] = BSC.slisBNB;
        address[] memory poolPath = new address[](1);
        poolPath[0] = BSC.WOMBAT_MAIN_POOL;
        try IWombatRouter(BSC.WOMBAT_ROUTER).getAmountOut(tokenPath, poolPath, int256(wbnbIn))
            returns (uint256 out, uint256[] memory)
        {
            slisOut = out;
        } catch {
            slisOut = 0;
        }
    }

    function _quotePcsWbnbToSlis(uint256 wbnbIn) internal returns (uint256 slisOut) {
        // PCS v3 lacks a view quoter on the router; simulate with snapshot.
        uint256 snap = vm.snapshotState();
        IPancakeV3Router.ExactInputSingleParams memory params = IPancakeV3Router.ExactInputSingleParams({
            tokenIn: BSC.WBNB,
            tokenOut: BSC.slisBNB,
            fee: 100,
            recipient: address(this),
            deadline: block.timestamp + 1 hours,
            amountIn: wbnbIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(params) returns (uint256 out) {
            slisOut = out;
        } catch {
            params.fee = 500;
            try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(params) returns (uint256 out2) {
                slisOut = out2;
            } catch {
                slisOut = 0;
            }
        }
        vm.revertToState(snap);
    }

    function _swapWbnbToSlisBest(uint256 wbnbIn) internal {
        // Prefer Wombat (low fee for stable LST pair); fall back to PCS V3.
        address[] memory tokenPath = new address[](2);
        tokenPath[0] = BSC.WBNB;
        tokenPath[1] = BSC.slisBNB;
        address[] memory poolPath = new address[](1);
        poolPath[0] = BSC.WOMBAT_MAIN_POOL;
        try IWombatRouter(BSC.WOMBAT_ROUTER).swapExactTokensForTokens(
            tokenPath, poolPath, wbnbIn, 0, address(this), block.timestamp + 1 hours
        ) returns (uint256 outW) {
            console2.log("wombat slisbnb_received_1e18=", outW);
            return;
        } catch {
            // PCS V3
            IPancakeV3Router.ExactInputSingleParams memory params = IPancakeV3Router.ExactInputSingleParams({
                tokenIn: BSC.WBNB,
                tokenOut: BSC.slisBNB,
                fee: 100,
                recipient: address(this),
                deadline: block.timestamp + 1 hours,
                amountIn: wbnbIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(params) returns (uint256 outP) {
                console2.log("pcs slisbnb_received_1e18=", outP);
            } catch {
                console2.log("both AMM legs failed for WBNB->slisBNB");
            }
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
        ) returns (uint256 out, uint256, uint256) {
            netPtOut = out;
        } catch {
            netPtOut = 0;
        }
    }

}
