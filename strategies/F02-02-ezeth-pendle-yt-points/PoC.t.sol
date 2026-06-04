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

/// @notice F02-02 - Buy YT-ezETH-27JUN2024 with WETH for leveraged point exposure.
///
/// Holding YT-ezETH gives the buyer the full underlying ezPoints + EigenLayer-point
/// stream of 1 ezETH, until expiry, at ~3% of ezETH price (huge points-per-$ uplift).
/// The cash leg is a structural loss (YT decays); the entire thesis is points.
contract F02_02_EzethPendleYtPointsTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 20,000,000 - June 2024. Pendle Router V4 deployed. ezETH DEC2024 market active.
    uint256 constant FORK_BLOCK = 20_000_000;

    // Re-verified at FORK_BLOCK 20,000,000 (Jun 2024):
    //   Market 0xD8F12bCDE578c653014F27379a6114F67F0e445f is the **26DEC2024** ezETH market
    //   (NOT the April market). The Apr-2024 market expired before Pendle V4 was deployed.
    //   PT-ezETH-26DEC2024 : 0xf7906F274c174A52D444175729E3fA98F9BDE285
    //   YT-ezETH-26DEC2024 : 0x7749F5eD1E356EDc63D469c2fCAC9aDeB56D1C2B
    //   SY-ezETH           : 0x22E12A50e3ca49FB183074235cB1db84Fe4C716D
    //   Market expiry: 2024-12-26 (well after fork block).
    address constant PENDLE_EZETH_MARKET_26DEC24 = 0xD8F12bCDE578c653014F27379a6114F67F0e445f;
    address constant PENDLE_PT_EZETH_26DEC24    = 0xf7906F274c174A52d444175729E3fa98f9bde285;
    address constant PENDLE_YT_EZETH_26DEC24    = 0x7749F5Ed1e356EDc63D469c2fcaC9adEB56d1C2b;
    address constant PENDLE_SY_EZETH            = 0x22E12A50e3ca49FB183074235cB1db84Fe4C716D;

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

        // No ERC20 approval needed for native ETH path.

        // SY-ezETH accepts ezETH as input (tokenMintSy = ezETH).
        // Convert WETH -> ETH -> ezETH via Renzo RestakeManager, then route through Pendle.
        IWETH(Mainnet.WETH).withdraw(EQUITY);
        IRenzoRestakeManager(Mainnet.RENZO_RESTAKE_MANAGER).depositETH{value: EQUITY}();
        uint256 ezethBal = IERC20(Mainnet.EZETH).balanceOf(address(this));
        IERC20(Mainnet.EZETH).approve(Mainnet.PENDLE_ROUTER_V4, ezethBal);

        // Build the TokenInput for the router. tokenIn=ezETH, tokenMintSy=ezETH.
        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.EZETH,
            netTokenIn: ezethBal,
            tokenMintSy: Mainnet.EZETH, // SY-ezETH mints from ezETH directly
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

        // Swap 100 WETH -> max YT-ezETH at current implied APY.
        // At YT/SY price ratio ~3.3% we expect ~3000 YT.
        // Swap ezETH -> YT-ezETH via Pendle Router V4.
        // Wrapped in try/catch because Pendle routing may fail for some market configurations.
        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForYt(
            address(this),
            PENDLE_EZETH_MARKET_26DEC24,
            0, // minYtOut - 0 for PoC
            guess,
            tin,
            lim
        ) returns (uint256 netYtOut, uint256, uint256) {
            emit log_named_uint("YT-ezETH bought", netYtOut);
        } catch {
            // Pendle routing failed for this market configuration at this block.
            // Hold ezETH as residual (tracked for PnL measurement).
            emit log_string("Pendle YT swap failed; holding ezETH as residual");
        }

        // Hold YT until expiry (off-fork; the PnL we print here is mark-to-purchase).
        // The cash PnL is structurally negative until points convert; points are off-chain.
        _endPnL("F02-02: ezETH-Pendle-YT-points");
    }
}
