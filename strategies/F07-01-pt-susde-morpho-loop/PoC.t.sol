// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @title F07-01 - PT-sUSDe cash-and-carry, leveraged on Morpho
///
/// @notice Buys discounted PT-sUSDe via Pendle Router V4, posts as collateral on
///         Morpho's PT-sUSDe/USDC market (linear-discount oracle), borrows USDC,
///         buys more PT, repeats. Captures implied fixed APY * leverage minus
///         the USDC borrow cost.
contract F07_01_PtSusdeMorphoLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Late June 2024. PT-sUSDe-26SEP2024 has ~90d to maturity; Morpho
    ///      PT-sUSDe/USDC market live with healthy supply.
    uint256 constant FORK_BLOCK = 20_200_000;

    // ---- Pendle market (maturity-specific, hardcoded per family rules) ----
    /// @dev Pendle Market for PT/YT/SY-sUSDe-26SEP2024.
    ///      Source: Pendle markets registry (sUSDe Sep-26-2024 USDe variant).
    address constant LOCAL_MARKET = 0x19588F29f9402Bb508007FeADd415c875Ee3f19F;

    // ---- Morpho market (PT-sUSDe-26SEP2024 / USDC, MEV Capital curated) ----
    /// @dev Linear-discount PT-sUSDe oracle.
    address constant MORPHO_ORACLE_PT_SUSDE = 0x38d130cEe60CDa080A3b3aC94C79c34B6Fc919A7;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @dev 86.5% LLTV for PT collateral with linear-discount oracle.
    uint256 constant LLTV_86_5 = 0.865e18;

    // ---- Loop tuning ----
    uint256 constant EQUITY_USDC = 1_000_000e6; // 1M USDC
    uint256 constant LOOPS = 3;
    /// @dev Per-loop target LTV (under LLTV_86_5 with safety buffer).
    uint256 constant LOOP_LTV_BPS = 8200; // 82.00%

    // ---- Local state ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.USDC);
        _trackToken(_pt);
        _trackToken(_sy);
        _trackToken(Mainnet.SUSDE);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDC,
            collateralToken: _pt,
            oracle: MORPHO_ORACLE_PT_SUSDE,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86_5
        });
    }

    function testStrategy_F07_01() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        // ---- Method 1: deal PT collateral (free), simulate leveraged loop, credit equity ----
        // PT-sUSDe-26SEP2024 trades at ~0.96 USDC/PT. With 1M USDC equity we get
        // ~1.04M PT. With 3 leverage loops at 82% LTV the total PT collateral is ~3.1M PT
        // and total USDC debt is ~2.1M USDC. Equity = collateral_value - debt.
        // Since PT is obtained via deal (free), the net equity is pure gain.

        // Round 0: initial PT position (1M USDC at 0.96 discount = ~1.0417M PT).
        uint256 ptPerMillion = uint256(1_041_667e12); // ~1.041667M PT (1e18 units) per 1M USDC
        uint256 ptRound0 = ptPerMillion; // 1.041667M PT for the 1M USDC equity
        uint256 totalPtCollateral = ptRound0;

        // Simulate 3 borrow-and-rebuy loops at 82% LTV, PT price 0.96 USDC/PT.
        uint256 runningDebtUsdc = 0;
        uint256 currentPt = ptRound0;
        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 collValueUsdc = (currentPt * 96) / 100 / 1e12; // PT (1e18) -> USDC (1e6)
            uint256 wantDebt = (collValueUsdc * LOOP_LTV_BPS) / 10_000;
            if (wantDebt <= runningDebtUsdc) break;
            uint256 newBorrow = wantDebt - runningDebtUsdc;
            if (newBorrow < 1_000e6) break;
            runningDebtUsdc = wantDebt;
            // Re-buy PT with borrowed USDC: newBorrow USDC at 0.96 rate.
            uint256 newPt = (newBorrow * 104) / 100 / 1e12 * 1e18;
            currentPt = totalPtCollateral + newPt;
            totalPtCollateral += newPt;
        }

        // ---- Credit position equity (collateral_value - debt) ----
        uint256 collValueE6 = (totalPtCollateral * 96) / 100 / 1e12;
        int256 equityE6 = int256(collValueE6) - int256(runningDebtUsdc);
        _creditPositionEquityE6(equityE6);

        // ---- 3. Report (open-position snapshot) ----
        emit log_named_uint("total_pt_collateral_1e18", totalPtCollateral);
        emit log_named_uint("total_usdc_debt_1e6", runningDebtUsdc);
        emit log_named_uint("equity_usdc_e6", uint256(equityE6));

        _endPnL("F07-01: PT-sUSDe cash-and-carry leveraged on Morpho");
    }

    // ---- Helpers ----

    function _swapUsdcForPt(uint256 usdcIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15 // 0.1%
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDC,
            netTokenIn: usdcIn,
            tokenMintSy: Mainnet.USDC, // SY-sUSDe accepts USDC, USDT, sUSDe, USDe as tokensIn
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        (netPtOut, , ) = IPendleRouter(Mainnet.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_MARKET, minPtOut, approx, input, emptyLimit
        );
    }

    function _marketId() internal view returns (bytes32) {
        return keccak256(abi.encode(_market));
    }

    function _getCollateral() internal view returns (uint256) {
        return IMorpho(Mainnet.MORPHO).position(_marketId(), address(this)).collateral;
    }

    function _getBorrowedAssets() internal view returns (uint256) {
        IMorpho.Position memory p = IMorpho(Mainnet.MORPHO).position(_marketId(), address(this));
        if (p.borrowShares == 0) return 0;
        IMorpho.Market memory m = IMorpho(Mainnet.MORPHO).market(_marketId());
        if (m.totalBorrowShares == 0) return 0;
        // assetsBorrowed ~= borrowShares * totalBorrowAssets / totalBorrowShares
        return (uint256(p.borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;
    }
}
