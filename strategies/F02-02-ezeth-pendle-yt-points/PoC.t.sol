// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IRenzoRestakeManager} from "src/interfaces/lrt/IRenzoRestakeManager.sol";

/// @notice Pendle Router V3 interface for swapExactTokenForYt.
/// V3 TokenInput has 6 fields (extra `address bulk` before pendleSwap).
/// Selector: 0xc4a9c7de.
interface IPendleRouterV3 {
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct SwapData {
        uint8 swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    /// @dev V3 TokenInput with `address bulk` field (set to address(0) for no fill).
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address bulk;           // V3-only: bulk-fill router (address(0) = no fill)
        address pendleSwap;
        SwapData swapData;
    }

    struct FillOrderParams {
        bytes order;
        bytes signature;
        uint256 makingAmount;
    }

    /// @dev V3 LimitOrderData (same structure as V4 but called via V3 router).
    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    /// @notice selector 0xc4a9c7de. Note: V3 does NOT have a LimitOrderData parameter.
    /// Returns only 2 values (netYtOut, netSyFee) — the V3 router does NOT return netSyInterm.
    function swapExactTokenForYt(
        address receiver,
        address market,
        uint256 minYtOut,
        ApproxParams calldata guessYtOut,
        TokenInput calldata input
    ) external payable returns (uint256 netYtOut, uint256 netSyFee);
}

/// @notice F02-02 - Buy YT-ezETH-26DEC2024 with ezETH for leveraged point exposure.
///
/// Holding YT-ezETH gives the buyer the full underlying ezPoints + EigenLayer-point
/// stream of 1 ezETH, until expiry, at ~3% of ezETH price (huge points-per-$ uplift).
/// The cash leg is a structural loss (YT decays); the entire thesis is points.
///
/// Uses Pendle V3 router (0x0000000001E4ef...) which has `swapExactTokenForYt`.
/// The V4 router (0x888...) only exposes mintPy/redeemPy functions at this fork block.
contract F02_02_EzethPendleYtPointsTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 19,800,000 - late Apr 2024. Pendle V3 router live; ezETH
    ///      26DEC2024 market active. SY-ezETH accepts [ezETH, address(0)=ETH].
    uint256 constant FORK_BLOCK = 19_800_000;

    // DEC24 market for ezETH on mainnet - verified via readTokens() on-chain:
    // Market LP: 0xD8F12bCDE578c653014F27379a6114F67F0e445f (expiry Dec 26 2024)
    // SY-ezETH : 0x22E12A50e3ca49FB183074235cB1db84Fe4C716D
    // PT-ezETH-26DEC2024: 0xf7906F274c174A52d444175729E3fa98f9bde285
    // YT-ezETH-26DEC2024: 0x7749F5Ed1e356EDc63D469c2fcaC9adEB56d1C2b
    address constant PENDLE_EZETH_MARKET_26DEC24 = 0xD8F12bCDE578c653014F27379a6114F67F0e445f;
    address constant PENDLE_PT_EZETH_26DEC24     = 0xf7906F274c174A52d444175729E3fa98f9bde285;
    address constant PENDLE_YT_EZETH_26DEC24     = 0x7749F5Ed1e356EDc63D469c2fcaC9adEB56d1C2b;

    uint256 constant EQUITY = 100 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.EZETH);
        _trackToken(PENDLE_YT_EZETH_26DEC24);
        _trackToken(PENDLE_PT_EZETH_26DEC24);
    }

    function testStrategy_F02_02() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // Step 1: WETH -> ETH -> ezETH via Renzo RestakeManager.
        // SY-ezETH only accepts [ezETH, ETH]; must convert WETH first.
        IWETH(Mainnet.WETH).withdraw(EQUITY);
        IRenzoRestakeManager(Mainnet.RENZO_RESTAKE_MANAGER).depositETH{value: EQUITY}();
        uint256 ezEthBal = IERC20(Mainnet.EZETH).balanceOf(address(this));
        require(ezEthBal > 0, "ezETH mint failed");

        // Step 2: Approve Pendle V3 router to pull ezETH.
        IERC20(Mainnet.EZETH).approve(Mainnet.PENDLE_ROUTER_V3, type(uint256).max);

        // Step 3: Build V3 TokenInput - tokenMintSy=ezETH (accepted by SY-ezETH).
        // V3 struct has `address bulk` = address(0) (no bulk-fill).
        IPendleRouterV3.TokenInput memory tin = IPendleRouterV3.TokenInput({
            tokenIn: Mainnet.EZETH,
            netTokenIn: ezEthBal,
            tokenMintSy: Mainnet.EZETH,
            bulk: address(0),           // V3: no bulk fill
            pendleSwap: address(0),
            swapData: IPendleRouterV3.SwapData({
                swapType: 0, // NONE
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        IPendleRouterV3.ApproxParams memory guess = IPendleRouterV3.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });

        // Step 4: Swap ezETH -> max YT-ezETH at current implied APY (via Pendle V3 router).
        // V3 swapExactTokenForYt has NO LimitOrderData parameter.
        IPendleRouterV3(Mainnet.PENDLE_ROUTER_V3).swapExactTokenForYt(
            address(this),
            PENDLE_EZETH_MARKET_26DEC24,
            0, // minYtOut - PoC skips slippage
            guess,
            tin
        );

        // Hold YT until expiry; cash PnL is structurally negative until points convert.
        _endPnL("F02-02: ezETH-Pendle-YT-points");
    }
}
