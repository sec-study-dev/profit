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

    // TODO verify: Pendle ezETH-27JUN2024 market and YT addresses at this block.
    address constant PENDLE_EZETH_MARKET_27JUN24 = 0xDe715330043799D7a80249660d1e6b07eC6b0393;
    address constant PENDLE_YT_EZETH_27JUN24    = 0xfb35Fd0095dD1096b1Ca49AD44d8C5812A201677;
    address constant PENDLE_SY_EZETH            = 0x22E12A50e3ca49FB183eA235aB78fB87B6Bb5d05;

    uint256 constant EQUITY = 100 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
        _trackToken(PENDLE_YT_EZETH_27JUN24);
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
            PENDLE_EZETH_MARKET_27JUN24,
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
