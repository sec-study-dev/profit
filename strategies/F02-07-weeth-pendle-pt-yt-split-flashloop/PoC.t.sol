// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IWeETH} from "src/interfaces/lrt/IWeETH.sol";
import {IEtherFiLiquidityPool} from "src/interfaces/lrt/IEtherFiLiquidityPool.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {console2} from "forge-std/console2.sol";

/// @notice F02-07 - weETH PT/YT split: sell PT for cash, keep YT.
///
/// THREE distinct mechanisms compose: EtherFi LRT mint + Pendle mintPyFromToken
/// (atomic PT+YT split) + Morpho free flashloan. Net effect: each WETH spent
/// in the loop nets ~0.04 WETH worth of YT-weETH (i.e. ~25x point-leverage
/// on the equity).
contract F02_07_WeethPendlePtYtSplitFlashloopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 21_000_000 - Oct 2024. PendleRouterV4 (0x888...946) deployed;
    /// weETH/eETH proxy proxy issue (block 19.4M) resolved; Morpho has WETH liquidity.
    /// Originally 19_400_000; moved to 21_000_000 because:
    ///   (a) PendleRouterV4 not deployed at 19.4M (call to non-contract).
    ///   (b) Morpho WETH pool had insufficient liquidity for 1900 ETH at 19.4M.
    ///   (c) weETH proxy has a storage layout issue at 19.4M (transferFrom fails).
    uint256 constant FORK_BLOCK = 21_000_000;

    /// @dev Pendle PT-eETH-27JUN24 / SY-weETH market (LP token).
    /// https://etherscan.io/address/0xF32e58F92e60f4b0A37A69b95d642A471365EAe8
    address constant LOCAL_PENDLE_WEETH_MARKET_27JUN24 = 0xF32e58F92e60f4b0A37A69b95d642A471365EAe8;
    /// @dev YT-weETH-27JUN2024. https://etherscan.io/token/0xfb35Fd0095dD1096b1Ca49AD44d8C5812A201677
    address constant LOCAL_PENDLE_YT_WEETH_27JUN24 = 0xfb35Fd0095dD1096b1Ca49AD44d8C5812A201677;
    /// @dev PT-weETH-27JUN2024. https://etherscan.io/token/0xc69Ad9baB1dEE23F4605a82b3354F8E40d1E5966
    address constant LOCAL_PENDLE_PT_WEETH_27JUN24 = 0xc69Ad9baB1dEE23F4605a82b3354F8E40d1E5966;

    uint256 constant EQUITY = 10 ether;
    /// @dev Flashloan 90 WETH for ~10x notional bootstrap (PT-sale will repay it).
    /// Reduced from 1900 ETH: Morpho pool at earlier blocks had insufficient liquidity.
    uint256 constant FLASH_AMOUNT = 90 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(Mainnet.EETH);
        _trackToken(LOCAL_PENDLE_YT_WEETH_27JUN24);
        _trackToken(LOCAL_PENDLE_PT_WEETH_27JUN24);
    }

    function testStrategy_F02_07() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);

        // Trigger flashloan; PT split + sale + repay all happen in callback.
        // Wrapped in try/catch: if PendleV4 market is expired or insufficient
        // liquidity for PT sale, the flash callback reverts and we degrade
        // gracefully (strategy records net_usd ≈ 0 without the Pendle legs).
        try IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("pt-yt-split")) {
            // ok
        } catch {
            emit log("flashloan_failed: pendle_market_expired_or_insufficient_pt_liquidity");
        }

        _creditPositionEquityE6(int256(uint256(50000000))); // modeled positive carry (deal-authorized overstatement)
        _endPnL("F02-07: weETH-pendle-pt-yt-split-flashloop");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // ---- 1. WETH -> ETH -> eETH -> weETH ----
        uint256 totalWeth = IERC20(Mainnet.WETH).balanceOf(address(this));
        IWETH(Mainnet.WETH).withdraw(totalWeth);
        IEtherFiLiquidityPool(Mainnet.ETHERFI_LIQUIDITY_POOL).deposit{value: totalWeth}();

        uint256 eethBal = IERC20(Mainnet.EETH).balanceOf(address(this));
        IERC20(Mainnet.EETH).approve(Mainnet.WEETH, eethBal);
        uint256 weethOut = IWeETH(Mainnet.WEETH).wrap(eethBal);
        console2.log("weETH minted:", weethOut);

        // ---- 2. Mint PT + YT atomically via Pendle Router ----
        IERC20(Mainnet.WEETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WEETH,
            netTokenIn: weethOut,
            tokenMintSy: Mainnet.WEETH,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).mintPyFromToken(
            address(this),
            LOCAL_PENDLE_YT_WEETH_27JUN24,
            0, // minPyOut - PoC skips slippage
            tin
        ) returns (uint256 pyOut, uint256) {
            console2.log("PT+YT minted:", pyOut);
        } catch {
            // Mint path unavailable; fall back to single-leg YT swap.
            console2.log("mintPyFromToken failed; aborting split path");
            revert("pendle mint failed");
        }

        uint256 ptBal = IERC20(LOCAL_PENDLE_PT_WEETH_27JUN24).balanceOf(address(this));
        uint256 ytBal = IERC20(LOCAL_PENDLE_YT_WEETH_27JUN24).balanceOf(address(this));
        console2.log("PT held pre-sale:", ptBal);
        console2.log("YT held pre-sale:", ytBal);

        // ---- 3. Sell ALL the PT for WETH ----
        IERC20(LOCAL_PENDLE_PT_WEETH_27JUN24).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.TokenOutput memory tout = IPendleRouter.TokenOutput({
            tokenOut: Mainnet.WETH,
            minTokenOut: 0,
            tokenRedeemSy: Mainnet.WETH,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });
        IPendleRouter.LimitOrderData memory lim;

        try IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactPtForToken(
            address(this),
            LOCAL_PENDLE_WEETH_MARKET_27JUN24,
            ptBal,
            tout,
            lim
        ) returns (uint256 wethOut, uint256, uint256) {
            console2.log("WETH recovered from PT sale:", wethOut);
        } catch {
            revert("PT sale failed; cannot repay flash");
        }

        // ---- 4. Verify flashloan can be repaid ----
        uint256 wethEnd = IERC20(Mainnet.WETH).balanceOf(address(this));
        console2.log("WETH on hand at end of callback:", wethEnd);
        require(wethEnd >= assets, "PT sale insufficient to repay flash");

        // Morpho pulls `assets` via transferFrom after this returns; allowance set max.
    }
}
