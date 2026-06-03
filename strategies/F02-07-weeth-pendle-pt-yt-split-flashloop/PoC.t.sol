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

/// @notice Pendle Router V3 interface for swapExactPtForToken.
/// V3 TokenOutput has 6 fields (extra `address bulk` between tokenRedeemSy and pendleSwap).
/// Selector: 0xb85f50ba.  Returns 2 values (netTokenOut, netSyFee) — no netSyInterm.
interface IPendleRouterV3Pt {
    struct SwapData {
        uint8 swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    /// @dev V3 TokenOutput with `address bulk` field between tokenRedeemSy and pendleSwap.
    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address bulk;           // V3-only: bulk-fill router (address(0) = no fill)
        address pendleSwap;
        SwapData swapData;
    }

    /// @notice selector 0xb85f50ba. Note: V3 does NOT have a LimitOrderData parameter.
    /// Returns only 2 values (netTokenOut, netSyFee).
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256 netSyFee);
}

/// @notice F02-07 - weETH PT/YT split via Pendle + Morpho flashloan.
///
/// Mechanism (three distinct protocols):
///   1. EtherFi: WETH -> ETH -> eETH -> weETH (LRT points + Lido pts).
///   2. Pendle: mintPyFromToken (V4 router) splits weETH into PT + YT
///              (YT held for ~25x points leverage per WETH equivalent).
///   3. Pendle: swapExactPtForToken (V3 router) sells PT back to weETH.
///   4. Morpho: weETH collateralizes WETH borrow to repay flashloan.
///              Net: equity stays as YT + weETH Morpho position.
///
/// SY-weETH (0xAC0047886a985071476a1186bE89222659970d65):
///   getTokensIn()  = [weETH, eETH, ETH/address(0)]
///   getTokensOut() = [weETH, eETH]
/// Therefore tokenMintSy = weETH and tokenRedeemSy = weETH (for PT sale).
///
/// Router note: mintPyFromToken uses V4 router; swapExactPtForToken uses V3 router.
/// V4 (0x888...) only has mint/redeem functions. V3 (0x0000000001E4ef...) has AMM swaps.
contract F02_07_WeethPendlePtYtSplitFlashloopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 19,800,000 - late Apr 2024. Pendle Router V4 live; weETH-27JUN24
    /// market valid (expiry Jun 27 2024 = ts 1719446400); Morpho weETH/WETH market
    /// has ~1747 WETH available. Morpho holds ~10k WETH total for flashloan.
    uint256 constant FORK_BLOCK = 19_800_000;

    /// @dev Pendle weETH-27JUN24 market (LP). SY, PT, YT verified via readTokens().
    /// SY: 0xAC0047886a985071476a1186bE89222659970d65
    /// PT: 0xc69Ad9baB1dEE23F4605a82b3354F8E40d1E5966
    /// YT: 0xfb35Fd0095dD1096b1Ca49AD44d8C5812A201677
    address constant LOCAL_PENDLE_WEETH_MARKET_27JUN24 = 0xF32e58F92e60f4b0A37A69b95d642A471365EAe8;
    address constant LOCAL_PENDLE_YT_WEETH_27JUN24 = 0xfb35Fd0095dD1096b1Ca49AD44d8C5812A201677;
    address constant LOCAL_PENDLE_PT_WEETH_27JUN24 = 0xc69Ad9baB1dEE23F4605a82b3354F8E40d1E5966;

    /// @dev Morpho weETH/WETH market params (same as F02-01 at block 19500000).
    /// At FORK_BLOCK 20_000_000: supply~6480 WETH, borrow~3850, available~2630.
    address constant MORPHO_ORACLE_WEETH_WETH = 0x3fa58b74e9a8eA8768eb33c8453e9C2Ed089A40a;
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    uint256 constant EQUITY = 100 ether;
    /// @dev Flash 200 WETH. Total notional = 300 WETH. After PT sale (recovers ~95-97%
    /// of weETH value), Morpho borrow provides WETH to repay flash.
    uint256 constant FLASH_AMOUNT = 200 ether;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(Mainnet.EETH);
        _trackToken(LOCAL_PENDLE_YT_WEETH_27JUN24);
        _trackToken(LOCAL_PENDLE_PT_WEETH_27JUN24);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: Mainnet.WEETH,
            oracle: MORPHO_ORACLE_WEETH_WETH,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });

        bytes32 derivedId = keccak256(abi.encode(_market));
        console2.log("derived weETH/WETH marketId:");
        console2.logBytes32(derivedId);
    }

    function testStrategy_F02_07() public {
        _fund(Mainnet.WETH, address(this), EQUITY);
        _startPnL();

        // Pre-approve Morpho for WETH (flash repay) and weETH (collateral).
        IERC20(Mainnet.WETH).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.WEETH).approve(Mainnet.MORPHO, type(uint256).max);

        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.WETH, FLASH_AMOUNT, abi.encode("pt-yt-split"));

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

        // ---- 2. Mint PT + YT from weETH via Pendle Router V4 ----
        // SY-weETH accepts weETH as tokenMintSy (confirmed via getTokensIn()).
        IERC20(Mainnet.WEETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WEETH,
            netTokenIn: weethOut,
            tokenMintSy: Mainnet.WEETH, // SY-weETH accepts weETH
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
            0,
            tin
        ) returns (uint256 pyOut, uint256) {
            console2.log("PT+YT minted:", pyOut);
        } catch {
            revert("Pendle mintPyFromToken failed");
        }

        uint256 ptBal = IERC20(LOCAL_PENDLE_PT_WEETH_27JUN24).balanceOf(address(this));
        uint256 ytBal = IERC20(LOCAL_PENDLE_YT_WEETH_27JUN24).balanceOf(address(this));
        console2.log("PT held:", ptBal);
        console2.log("YT held (kept for points):", ytBal);

        // ---- 3. Sell ALL PT for weETH via Pendle V3 router ----
        // SY-weETH outputs weETH (confirmed via getTokensOut()). We cannot redeem to WETH.
        // V4 router (0x888...) does NOT have swapExactPtForToken; use V3 router (0x0000000001E4ef...)
        // V3 TokenOutput has a `bulk` field (set address(0) = no bulk fill).
        IERC20(LOCAL_PENDLE_PT_WEETH_27JUN24).approve(Mainnet.PENDLE_ROUTER_V3, type(uint256).max);

        IPendleRouterV3Pt.TokenOutput memory tout = IPendleRouterV3Pt.TokenOutput({
            tokenOut: Mainnet.WEETH,         // SY-weETH outputs weETH
            minTokenOut: 0,
            tokenRedeemSy: Mainnet.WEETH,    // SY-weETH accepts weETH as redeem token
            bulk: address(0),                // V3: no bulk fill
            pendleSwap: address(0),
            swapData: IPendleRouterV3Pt.SwapData({
                swapType: 0,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        try IPendleRouterV3Pt(Mainnet.PENDLE_ROUTER_V3).swapExactPtForToken(
            address(this),
            LOCAL_PENDLE_WEETH_MARKET_27JUN24,
            ptBal,
            tout
        ) returns (uint256 weethRecovered, uint256) {
            console2.log("weETH recovered from PT sale:", weethRecovered);
        } catch {
            revert("PT sale failed");
        }

        // ---- 4. Supply recovered weETH as Morpho collateral, borrow WETH to repay flash ----
        uint256 weethForMorpho = IERC20(Mainnet.WEETH).balanceOf(address(this));
        console2.log("weETH for Morpho collateral:", weethForMorpho);
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, weethForMorpho, address(this), "");
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        uint256 wethEnd = IERC20(Mainnet.WETH).balanceOf(address(this));
        require(wethEnd >= assets, "insufficient WETH for flash repay");
        console2.log("WETH on hand for repay:", wethEnd);
        // Morpho pulls `assets` WETH back after this returns.
    }
}
