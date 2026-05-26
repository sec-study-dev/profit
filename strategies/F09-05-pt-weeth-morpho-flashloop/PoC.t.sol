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

/// @notice F09-05 - PT-weETH-26DEC2024/WETH 86% LLTV Morpho loop bootstrapped by
///         Morpho's zero-fee flashLoan and Pendle's PT auction. Three-mechanism:
///
///         Mechanism 1: Morpho Blue free flashLoan (callback-style, 0 bps fee)
///         Mechanism 2: Pendle V4 swapExactTokenForPt (WETH -> PT-weETH at
///                      discount-to-par)
///         Mechanism 3: EtherFi weETH staking (the carry that backs PT redemption
///                      at maturity)
///
///         Single-tx open:
///           1. flashLoan WETH from Morpho.
///           2. swapExactTokenForPt on Pendle: WETH -> PT-weETH-26DEC2024 at
///              the live AMM discount (~3-4% to par over remaining duration).
///           3. supplyCollateral PT-weETH to Morpho PT-weETH/WETH market,
///              borrow WETH = flash amount, repay flash via outer approval.
///
///         Carry math: PT pulls toward 1 weETH at maturity (Dec 26, 2024).
///         At a 4% PT discount and 4.5x leverage we lock ~18% absolute return
///         to maturity on equity. This is the canonical "PT cash-and-carry" but
///         done with Morpho's free flash instead of an Aave 5-bps flash.
contract F09_05_PtWeethMorphoFlashloopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Constants ----

    /// @dev Mid-August 2024. PT-weETH-26DEC2024 has ~4.5 months to maturity;
    ///      Morpho PT-weETH/WETH market live and deep on the curated Gauntlet
    ///      deployment (PendleSparkLinearDiscount oracle).
    uint256 constant FORK_BLOCK = 20_650_000;

    /// @dev Pendle V4 market for PT/YT/SY-weETH-26DEC2024.
    address constant PENDLE_MARKET_WEETH_26DEC24 = 0x7d372819240D14fB477f17b964f95F33BeB4c704;

    /// @dev Morpho market id for PT-weETH-26DEC2024 / WETH 86% LLTV. The
    ///      MarketParams are recovered live via `idToMarketParams(id)` and
    ///      asserted in setUp. This id was observed on Morpho's public registry
    ///      for the Gauntlet-curated PT-weETH/WETH-86 market.
    bytes32 constant PT_WEETH_WETH_MARKET_ID =
        0xc581c5f70bd1afa283eed57d1418c6432cbff1d862f94eaf58fdd4e46afbb67e;

    uint256 constant EQUITY = 30 ether;
    /// @dev 3.5x flash on equity, total notional ~4.5x equity. Stays well
    ///      inside 86% LLTV (loop opens at ~78% LTV given PT discount).
    uint256 constant FLASH_AMOUNT = 105 ether;

    IMorpho.MarketParams internal _market;
    address internal _pt;
    address internal _sy;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);

        // Recover market params from Morpho's on-chain registry (avoids
        // hard-coding the PendleSparkLinearDiscount oracle address, which is
        // maturity-specific and was redeployed once during 2024).
        _market = IMorpho(Mainnet.MORPHO).idToMarketParams(PT_WEETH_WETH_MARKET_ID);
        require(_market.loanToken == Mainnet.WETH, "F09-05: loanToken must be WETH");
        require(_market.lltv == 0.86e18, "F09-05: market LLTV not 86%");

        (_sy, _pt, _yt) = IPendleMarket(PENDLE_MARKET_WEETH_26DEC24).readTokens();
        require(_market.collateralToken == _pt, "F09-05: market collateral != PT-weETH");

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(_pt);
        _trackToken(_sy);
    }

    function testStrategy_F09_05() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // Outer-scope approvals: Morpho pulls WETH (flash repay + supply),
        // Pendle pulls WETH for the swap, Morpho pulls PT for collateral.
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("pt-weeth-loop"));

        // Position snapshot after open.
        IMorpho.Position memory pos = IMorpho(Mainnet.MORPHO).position(PT_WEETH_WETH_MARKET_ID, address(this));
        console2.log("PT-weETH collateral (1e18) =", pos.collateral);
        console2.log("borrowShares              =", pos.borrowShares);
        console2.log("residual PT on contract   =", IERC20(_pt).balanceOf(address(this)));

        _endPnL("F09-05: PT-weETH-26DEC2024 Morpho flashloop");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // Step 1: swap all WETH (equity + flash = 135 ether) into PT-weETH on
        // Pendle. The router routes WETH -> SY-weETH (via weETH/eETH mint or
        // direct) -> PT via the AMM, picking up the live PT discount.
        uint256 totalWeth = IERC20(Mainnet.WETH).balanceOf(address(this));
        uint256 ptOut = _swapWethForPt(totalWeth);
        require(ptOut > 0, "pendle: zero PT out");

        // Step 2: supply PT-weETH as Morpho collateral.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, ptOut, address(this), "");

        // Step 3: borrow WETH = flash principal so we can repay. Morpho's
        // post-callback safeTransferFrom pulls those `assets` back via the
        // outer max-approval.
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));
    }

    function _swapWethForPt(uint256 wethIn) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethIn,
            tokenMintSy: Mainnet.WETH, // SY-weETH accepts WETH (router unwraps and mints)
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), PENDLE_MARKET_WEETH_26DEC24, 0, approx, input, emptyLimit
        );
    }
}
