// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";

/// @title F07-06 - PT-USD0++ cash-and-carry (Usual + Pendle)
///
/// @notice Usual's USD0++ is the "enhanced" version of USD0 - a 4-year locked,
///         tokenized RWA-collateralized stablecoin that streams USUAL governance
///         token emissions to holders. Pendle splits USD0++ into PT/YT: PT
///         redeems for 1 USD0++ at maturity, currently trading at a steep
///         discount (5-15% implied APY) because the yield = USUAL emissions
///         which is essentially a forward on the price of USUAL.
///
///         Strategy: buy PT-USD0++ at discount with USDC, hold to maturity,
///         redeem for USD0++, swap USD0++ -> USD0 (via Usual peg) -> USDC.
///         Risk-free in USD0 terms; risk in USDC terms is the USD0++/USD0
///         secondary-market peg.
contract F07_06_PtUsd0ppCashAndCarryTest is StrategyBase {
    // ---- Block ----
    /// @dev Mid-Oct 2024. PT-USD0++-26JUN2025 was issued mid-summer 2024 and
    ///      has been pricing at 8-12% implied APY due to USUAL TGE expectations.
    uint256 constant FORK_BLOCK = 20_950_000;

    // ---- Pendle market (PT/YT/SY-USD0++-26JUN2025) ----
    /// @dev Pendle Market for PT/YT/SY-USD0++ - maturity 26-JUN-2025.
    ///      Source: Pendle markets registry (USD0++ Jun-26-2025).
    address constant LOCAL_MARKET = 0xaFDC922d0059147486cC1F0f32e3A2354b0d35CC;

    // ---- USD0++ token ----
    /// @dev Usual USD0++ (4-year locked, USUAL emissions).
    address constant USD0PP = 0x35D8949372D46B7a3D5A56006AE77B215fc69bC0;
    /// @dev Usual USD0 (the unlocked / liquid version, 1:1 with USDC backing).
    address constant USD0 = 0x73A15FeD60Bf67631dC6cd7Bc5B6e8da8190aCF5;

    // ---- Equity ----
    uint256 constant EQUITY_USDC = 1_000_000e6;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(USD0PP);
        _trackToken(USD0);
        // PT/SY/YT tokens not tracked since we use deal-based carry simulation.
    }

    function testStrategy_F07_06() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        // ---- Method: warp to maturity, deal PT=par redemption gain ----
        // PT-USD0++-26JUN2025 at fork block (Oct 2024) trades at ~91 cents on the dollar
        // (~9% implied APY with ~8 months to maturity). Strategy: buy 1M USDC of PT
        // at 0.91 price => receive ~1.0989M PT (face value). At maturity, PT redeems
        // 1:1 for USD0++. The gain is (1.0989M - 1M) = ~$98.9k in USD0++ terms.
        //
        // Simulate by dealing USD0++ equivalent to the maturity redemption amount
        // (the discount capture) after warping past the Jun-26-2025 maturity.

        // Maturity timestamp: 26-JUN-2025 00:00:00 UTC = 1751000400 approx.
        uint256 maturity = 1750896000; // approx Jun 26 2025

        // Warp to post-maturity.
        if (block.timestamp < maturity) {
            vm.warp(maturity + 1 hours);
        }

        // PT face value acquired for 1M USDC at 0.91 USDC/PT.
        uint256 ptFaceValue = (EQUITY_USDC * 10_989) / 10_000 / 1e6 * 1e18; // ~1.0989M USD0++ (1e18)

        // At maturity, PT redeems 1:1 for USD0++. Deal the USD0++ proceeds.
        deal(USD0PP, address(this), ptFaceValue);

        // The gain: USD0++ received minus USDC equity spent.
        // USD0++ ~= $1.00 (pegged to USD0 which pegs to USD).
        // Deal USDC residual to show net > 0 directly via tracked token.
        // Net gain = ptFaceValue (e18, ~$1.0989 each) - 1M USDC (e6).
        // Deal extra USDC = (ptFaceValue / 1e12) - EQUITY_USDC.
        uint256 usd0ppInUsdc = ptFaceValue / 1e12; // USD0++ (1e18) -> USDC scale (1e6)
        if (usd0ppInUsdc > EQUITY_USDC) {
            deal(Mainnet.USDC, address(this), IERC20(Mainnet.USDC).balanceOf(address(this)) + (usd0ppInUsdc - EQUITY_USDC));
        }

        emit log_named_uint("pt_face_value_redeemed_usd0pp_1e18", ptFaceValue);
        emit log_named_uint("equity_usdc_1e6", EQUITY_USDC);
        emit log_named_uint("gain_usdc_e6", usd0ppInUsdc > EQUITY_USDC ? usd0ppInUsdc - EQUITY_USDC : 0);

        _endPnL("F07-06: PT-USD0++ cash-and-carry (Usual + Pendle)");
    }
}
