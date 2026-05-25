// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-03 — PT-sUSDe leveraged buy on Morpho with USDC flashloan
/// @notice Cash-and-carry: borrow USDC via Morpho free flashloan, swap USDC->USDe
///         on Curve, buy PT-sUSDe-26SEP2024 on Pendle, post PT as Morpho
///         collateral on a curated PT-sUSDe/USDC market, borrow USDC equal to
///         the flash, repay. Result: ~5x PT-sUSDe stack on the original equity.
///         PT-sUSDe matures at par into 1 sUSDe — PnL is the fixed discount
///         (~12-20% annualised premium) × leverage.
contract F08_03_PtSusdeMorphoFlashLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 19,950,000 (~Jun 2024). PT-sUSDe-26SEP2024 active on Pendle;
    ///      Morpho PT-sUSDe-26SEP/USDC market curated by MEV-Capital with 86% LLTV.
    uint256 constant FORK_BLOCK = 19_950_000;

    /// @dev Pendle PT-sUSDe-26SEP2024 market and PT addresses.
    ///      TODO verify: these are best-known addresses from Pendle SDK at the
    ///      fork block. If the market id differs, override in setUp.
    address constant PENDLE_PT_SUSDE_26SEP24 = 0xa0021EF8970104c2d008F38D92f115ad56a9B8e1;
    address constant PENDLE_MARKET_PT_SUSDE_26SEP24 = 0xbBf399db59A845066aAFce9AE55e68c505FA97B7;

    /// @dev Curve USDe/USDC pool (coin 0 = USDe, coin 1 = USDC).
    ///      Same pool used in F08-01 / F08-02.
    address constant CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Morpho PT-sUSDe / USDC 86% LLTV market parameters.
    ///      TODO verify: oracle and IRM at fork block.
    address constant MORPHO_ORACLE_PT_SUSDE_USDC = 0x5d916980d5Ae1737a8330Bf24dF812b2911Aae25;
    address constant MORPHO_IRM_ADAPTIVE_CURVE   = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_86 = 0.86e18;

    uint256 constant EQUITY_USDC = 100_000e6;
    /// @dev 4x leverage on equity -> ~5x total notional.
    uint256 constant FLASH_USDC = 400_000e6;

    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(PENDLE_PT_SUSDE_26SEP24);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDC,
            collateralToken: PENDLE_PT_SUSDE_26SEP24,
            oracle: MORPHO_ORACLE_PT_SUSDE_USDC,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });
    }

    function testStrategy_F08_03() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        // Approvals (USDC needs zero-approve dance only on USDT; USDC is fine).
        IERC20(Mainnet.USDC).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(PENDLE_PT_SUSDE_26SEP24).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.USDC).approve(CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);

        // Trigger the loop via Morpho free flashloan. Heavy lifting in callback.
        IMorpho(Mainnet.MORPHO).flashLoan(Mainnet.USDC, FLASH_USDC, abi.encode("pt-loop"));

        // After flash callback: we hold PT-sUSDe collateral on Morpho equal to ~5x
        // equity and a USDC debt equal to FLASH_USDC. PnL accrues as PT-sUSDe
        // price drifts toward par (1 sUSDe) at maturity.
        _endPnL("F08-03: PT-sUSDe Morpho flashloop");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        require(msg.sender == Mainnet.MORPHO, "only morpho");

        // Step A: USDC -> USDe via Curve. Total in = EQUITY_USDC + assets.
        uint256 totalUsdc = IERC20(Mainnet.USDC).balanceOf(address(this));
        uint256 minUsde = (totalUsdc * 9950) / 10_000 * 1e12; // 50 bps tolerance, scale 6->18
        uint256 usdeOut = ICurveStableSwap(CURVE_USDE_USDC).exchange(
            int128(1), int128(0), totalUsdc, minUsde
        );

        // Step B: USDe -> PT-sUSDe-26SEP2024 via Pendle router.
        IPendleRouter.TokenInput memory tin = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDE,
            netTokenIn: usdeOut,
            tokenMintSy: Mainnet.USDE,
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
        IPendleRouter.LimitOrderData memory lim; // zeros

        (uint256 ptOut,,) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this),
            PENDLE_MARKET_PT_SUSDE_26SEP24,
            0,
            guess,
            tin,
            lim
        );
        require(ptOut > 0, "pendle: zero PT out");

        // Step C: post PT as Morpho collateral.
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, ptOut, address(this), "");

        // Step D: borrow USDC equal to flash principal (so we can repay).
        IMorpho(Mainnet.MORPHO).borrow(_market, assets, 0, address(this), address(this));

        // Morpho pulls back `assets` after this returns via safeTransferFrom on the
        // outer approval. No-op here; control returns to flashLoan() which finishes.
    }
}
