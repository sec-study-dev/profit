// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {IMorphoFlashLoanCallback} from "src/interfaces/common/IFlashLoanReceiver.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-03 - PT-sUSDe leveraged buy on Morpho with USDC flashloan
/// @notice Cash-and-carry: borrow USDC via Morpho free flashloan, swap USDC->USDe
///         on Curve, buy PT-sUSDe-26SEP2024 on Pendle, post PT as Morpho
///         collateral on a curated PT-sUSDe/USDC market, borrow USDC equal to
///         the flash, repay. Result: ~5x PT-sUSDe stack on the original equity.
///         PT-sUSDe matures at par into 1 sUSDe - PnL is the fixed discount
///         (~12-20% annualised premium) * leverage.
contract F08_03_PtSusdeMorphoFlashLoopTest is StrategyBase, IMorphoFlashLoanCallback {
    // ---- Pinned constants ----

    /// @dev Block 21,400,000 (~Dec 2024). PT-sUSDe-26DEC2024 active on Pendle;
    ///      Morpho PT-sUSDe-26DEC2024/USDC market (91.5% LLTV) live.
    uint256 constant FORK_BLOCK = 21_400_000;

    /// @dev Pendle PT-sUSDe-26DEC2024 market.
    ///      SY-sUSDe-26DEC2024 only accepts USDe and sUSDe as tokensIn.
    address constant LOCAL_PENDLE_MARKET_PT_SUSDE_26DEC24 =
        0xa0ab94DeBB3cC9A7eA77f3205ba4AB23276feD08;

    /// @dev Curve USDe/USDC pool (coin 0 = USDe, coin 1 = USDC).
    ///      Same pool used in F08-01 / F08-02. setUp() asserts coin ordering.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Morpho PT-sUSDe-26DEC24 / USDC 91.5% LLTV market parameters.
    address constant LOCAL_MORPHO_ORACLE_PT_SUSDE_USDC =
        0xB35B25ADC53157f4b76a0eECc94EfE915A0AA968;
    address constant LOCAL_MORPHO_IRM_ADAPTIVE_CURVE =
        0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    uint256 constant LLTV_915 = 0.915e18;

    uint256 constant EQUITY_USDC = 100_000e6;
    /// @dev 4x leverage on equity -> ~5x total notional.
    uint256 constant FLASH_USDC = 400_000e6;

    IMorpho.MarketParams internal _market;
    address internal _pt;
    address internal _sy;
    address internal _yt;

    function setUp() public {
        _fork(FORK_BLOCK);
        // Read SY/PT/YT directly from the Pendle market - avoids hardcoding the
        // PT token address (which has differed across Pendle factory redeploys).
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_PENDLE_MARKET_PT_SUSDE_26DEC24).readTokens();

        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(_pt);

        // Sanity-check Curve pool ordering.
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F08-03: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F08-03: curve coin1 != USDC"
        );

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDC,
            collateralToken: _pt,
            oracle: LOCAL_MORPHO_ORACLE_PT_SUSDE_USDC,
            irm: LOCAL_MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_915
        });

        // Best-effort: confirm the constructed market exists on Morpho by
        // recovering its params via idToMarketParams. If the market does not
        // exist at the fork block, Morpho returns the zero struct; we surface
        // a clear error in that case rather than failing inside borrow().
        bytes32 mid = keccak256(abi.encode(_market));
        IMorpho.MarketParams memory onchain = IMorpho(Mainnet.MORPHO).idToMarketParams(mid);
        require(onchain.loanToken == Mainnet.USDC, "F08-03: PT-sUSDe-26DEC2024/USDC market missing at fork block");
    }

    function testStrategy_F08_03() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        // Approvals (USDC needs zero-approve dance only on USDT; USDC is fine).
        IERC20(Mainnet.USDC).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);
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
        uint256 usdeOut = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), totalUsdc, minUsde
        );

        // Step B: USDe -> PT-sUSDe-26DEC2024 via Pendle router.
        // SY-sUSDe-26DEC2024 accepts USDe and sUSDe as tokenMintSy (not USDC).
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
            LOCAL_PENDLE_MARKET_PT_SUSDE_26DEC24,
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
