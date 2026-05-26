// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F09-07 - PT-USD0++/USDC Morpho leveraged carry via Morpho free flash.
///         Three-mechanism stack:
///
///         Mechanism 1: Morpho Blue zero-fee flashLoan on USDC
///         Mechanism 2: Pendle V4 swapExactTokenForPt (USDC -> PT-USD0++-26JUN2025)
///         Mechanism 3: Usual Protocol USD0++ bonded stable (PT redeems for
///                      USD0++ at maturity which is USDC-redeemable via the
///                      Usual peg / treasury)
///
///         This is a *leveraged* extension of F07-06 (unleveraged PT-USD0++
///         cash-and-carry). Morpho's curated PT-USD0++/USDC market with 86%
///         LLTV (Gauntlet-deployed PendleSparkLinearDiscount oracle) lets the
///         PT discount be levered ~6x against USDC borrows.
contract F09_07_PtUsd0ppMorphoFlashLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Constants ----

    /// @dev Mid-Oct 2024. PT-USD0++-26JUN2025 active on Pendle with a ~9%
    ///      implied APY discount; Morpho PT-USD0++/USDC 86% market live with
    ///      Gauntlet curation and USDC supply available.
    uint256 constant FORK_BLOCK = 20_950_000;

    /// @dev Pendle V4 market for PT/YT/SY-USD0++-26JUN2025.
    address constant PENDLE_MARKET_USD0PP_26JUN25 = 0xaFDC922d0059147486cC1F0f32e3A2354b0d35CC;

    /// @dev Morpho marketId for PT-USD0++-26JUN2025 / USDC 86% LLTV (Gauntlet
    ///      curated; PendleSparkLinearDiscount oracle). MarketParams recovered
    ///      live via idToMarketParams in setUp.
    bytes32 constant PT_USD0PP_USDC_MARKET_ID =
        0xa921ef34e2fc7a27ccc50ae7e4b154e16c9799d3387c0b3b3b3a3d4b3c3a3b3c;

    /// @dev Usual USD0++ (the PT redeems into 1 USD0++ at maturity).
    address constant USD0PP = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;

    uint256 constant EQUITY_USDC = 200_000e6; // 200k USDC
    /// @dev 4x flash on equity -> 5x total notional. With PT priced ~0.95 USDC
    ///      and 86% LLTV, opens at ~76% LTV (10% buffer).
    uint256 constant FLASH_USDC = 800_000e6;

    IMorpho.MarketParams internal _market;
    address internal _pt;
    address internal _sy;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);

        // Recover MarketParams (avoids hard-coding the PendleSparkLinearDiscount
        // oracle, which is maturity-specific).
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(PT_USD0PP_USDC_MARKET_ID);
        require(_market.loanToken == Mainnet.USDC, "F09-07: loanToken not USDC");
        require(_market.lltv == 0.86e18, "F09-07: LLTV not 86%");

        (_sy, _pt, _yt) = IPendleMarket(PENDLE_MARKET_USD0PP_26JUN25).readTokens();
        require(_market.collateralToken == _pt, "F09-07: market collateral != PT-USD0++");

        _trackToken(Mainnet.USDC);
        _trackToken(USD0PP);
        _trackToken(_pt);
        _trackToken(_sy);
    }

    function testStrategy_F09_07() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        IERC20(Mainnet.USDC).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.USDC).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.USDC, FLASH_USDC, abi.encode("pt-usd0pp-loop"));

        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(PT_USD0PP_USDC_MARKET_ID, address(this));
        console2.log("PT-USD0++ collateral (1e18) =", pos.collateral);
        console2.log("USDC debt shares            =", pos.borrowShares);

        _endPnL("F09-07: PT-USD0++ Morpho flashloop (Usual + Pendle + Morpho)");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // Step 1: swap all USDC (equity + flash = 1M USDC) -> PT-USD0++ via
        // Pendle. Router internally routes USDC -> USD0 -> USD0++ -> PT, all
        // through the Usual peg-router for tokenMintSy=USDC.
        uint256 totalUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        uint256 ptOut = _swapUsdcForPt(totalUsdc);
        require(ptOut > 0, "pendle: zero PT out");

        // Step 2: post PT-USD0++ as Morpho collateral.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, ptOut, address(this), "");

        // Step 3: borrow USDC = flash principal so we can repay.
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // Morpho's safeTransferFrom pulls `assets` USDC back.
    }

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
            tokenIn: Mainnet.USDC,
            netTokenIn: usdcIn,
            tokenMintSy: Mainnet.USDC, // SY-USD0++ accepts USDC via Usual peg-router
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), PENDLE_MARKET_USD0PP_26JUN25, 0, approx, input, emptyLimit
        );
    }
}
