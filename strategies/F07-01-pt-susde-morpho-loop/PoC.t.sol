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
    address constant LOCAL_MARKET = 0x19588f29f9402bb508007feadd415c875ee3f19f;

    // ---- Morpho market (PT-sUSDe-26SEP2024 / USDC, MEV Capital curated) ----
    /// @dev Linear-discount PT-sUSDe oracle.
    address constant MORPHO_ORACLE_PT_SUSDE = 0x38d130cee60cda080a3b3ac94c79c34b6fc919a7;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870ac11d48b15db9a138cf899d20f13f79ba00bc;
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

        // Approvals
        IERC20(Mainnet.USDC).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        // ---- 1. Initial PT buy ----
        uint256 ptBought = _swapUsdcForPt(EQUITY_USDC, 0 /* minOut, slippage gated off-chain */);

        // ---- 2. Loop: supply PT, borrow USDC, buy more PT ----
        uint256 totalPt = ptBought;
        for (uint256 i = 0; i < LOOPS; i++) {
            // Supply this round's PT collateral.
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, IERC20(_pt).balanceOf(address(this)), address(this), "");

            // Compute headroom. The Morpho oracle is a linear-discount oracle that
            // returns PT/USDC at ~face-value-on-maturity / discount-factor. For the
            // PoC we approximate by tagging PT 1:1 with USDC face on a 6-decimal
            // scale (PT is 18 dec, USDC 6 dec) discounted by `discBps`.
            //
            // For a precise figure, call _market.oracle.price() and apply Morpho's
            // SCALE_FACTOR (1e36 / oracle.SCALE_FACTOR()). For brevity in PoC we
            // assume an effective PT price of 0.96 USDC/PT (face / sqrt(1 + apr*t)).
            uint256 totalSupplied = _getCollateral();
            // collateral_value_USDC = totalSupplied (1e18) * 0.96 / 1e12
            uint256 collValueUSDC = (totalSupplied * 96) / 100 / 1e12;
            uint256 borrowUSDC = (collValueUSDC * LOOP_LTV_BPS) / 10_000;
            // Subtract any previously borrowed amount; for simplicity in PoC, borrow
            // the increment only.
            uint256 alreadyBorrowed = _getBorrowedAssets();
            if (borrowUSDC <= alreadyBorrowed) break;
            uint256 toBorrow = borrowUSDC - alreadyBorrowed;
            if (toBorrow < 1_000e6) break;

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrow, 0, address(this), address(this));

            // Buy more PT with freshly borrowed USDC.
            uint256 newPt = _swapUsdcForPt(toBorrow, 0);
            totalPt += newPt;
        }

        // Final supply of any leftover PT to lock in maximum leverage.
        uint256 trailing = IERC20(_pt).balanceOf(address(this));
        if (trailing > 0) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, trailing, address(this), "");
        }

        // ---- 3. Report (open-position snapshot) ----
        emit log_named_uint("total_pt_collateral_1e18", _getCollateral());
        emit log_named_uint("total_usdc_debt_1e6", _getBorrowedAssets());
        emit log_named_uint("equity_usdc_1e6", EQUITY_USDC);

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
