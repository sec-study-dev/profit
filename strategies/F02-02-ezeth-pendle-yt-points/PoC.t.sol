// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IEzETH} from "src/interfaces/lrt/IEzETH.sol";
import {IRenzoRestakeManager} from "src/interfaces/lrt/IRenzoRestakeManager.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";

/// @notice F02-02 — Buy YT-ezETH-27JUN2024 with WETH for leveraged point exposure.
///
/// Holding YT-ezETH gives the buyer the full underlying ezPoints + EigenLayer-point
/// stream of 1 ezETH, until expiry, at ~3% of ezETH price (huge points-per-$ uplift).
/// The cash leg is a structural loss (YT decays); the entire thesis is points.
contract F02_02_EzethPendleYtPointsTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 19,400,000 — early March 2024, Pendle ezETH market hot.
    uint256 constant FORK_BLOCK = 19_400_000;

    // Verified: at FORK_BLOCK 19,400,000 (early Mar 2024) the live Pendle ezETH
    // market on Ethereum mainnet is the **25APR2024** maturity (the 27JUN2024
    // maturity is Arbitrum-only — `0x8ea5040d...` on Arbiscan; mainnet does not
    // have a 27JUN24 ezETH listing — the prior addresses confused weETH/zircuit).
    // Sources:
    //   PT-ezETH-25APR2024 : https://etherscan.io/token/0xeee8aed1957ca1545a0508afb51b53cca7e3c0d1
    //   YT-ezETH-25APR2024 : https://etherscan.io/token/0x256fb830945141f7927785c06b65dabc3744213c
    //   SY-ezETH           : https://etherscan.io/token/0x22e12a50e3ca49fb183074235cb1db84fe4c716d
    // The market (LP) address below is the canonical PendleMarketV3 deployed by
    // Pendle's MarketFactoryV3 (0x1A6fCc85...) wrapping the PT/SY pair above.
    address constant PENDLE_EZETH_MARKET_25APR24 = 0xD8F12bCDE578c653014F27379a6114F67F0e445f;
    address constant PENDLE_PT_EZETH_25APR24    = 0xeEE8aED1957ca1545a0508AFB51b53cCA7e3C0d1;
    address constant PENDLE_YT_EZETH_25APR24    = 0x256Fb830945141f7927785c06b65dAbc3744213c;
    address constant PENDLE_SY_EZETH            = 0x22E12A50e3ca49FB183074235cB1db84Fe4C716D;

    uint256 constant EQUITY = 100 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
        _trackToken(PENDLE_YT_EZETH_25APR24);
        _trackToken(PENDLE_PT_EZETH_25APR24);
    }

    function testStrategy_F02_02() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // Approve Pendle router to pull WETH.
        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        // Build the TokenInput for the router. SY-ezETH accepts ETH/WETH/ezETH as input.
        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: EQUITY,
            tokenMintSy: Mainnet.WETH,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0, // NONE
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        IPendleRouter.ApproxParams memory guess = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });

        IPendleRouter.LimitOrderData memory lim; // all-zeros (no limit fills)

        // Swap 100 WETH → max YT-ezETH at current implied APY.
        // At YT/SY price ratio ~3.3% we expect ~3000 YT.
        IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this),
            PENDLE_EZETH_MARKET_25APR24,
            0, // minPtOut — leave 0 in PoC; production must set slippage
            guess,
            tin,
            lim
        );

        // Hold YT until expiry (off-fork; the PnL we print here is mark-to-purchase).
        // The cash PnL is structurally negative until points convert; points are off-chain.
        _endPnL("F02-02: ezETH-Pendle-YT-points");
    }
}
