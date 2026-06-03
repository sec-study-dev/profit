// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F07-01 - PT-sUSDe cash-and-carry, leveraged on Morpho
///
/// @notice Buys discounted PT-sUSDe via Pendle Router V4, posts as collateral on
///         Morpho's PT-sUSDe/USDC market (linear-discount oracle), borrows USDC,
///         buys more PT, repeats. Captures implied fixed APY * leverage minus
///         the USDC borrow cost.
contract F07_01_PtSusdeMorphoLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Jan 2025. PT-sUSDe-27MAR2025 has ~90d to maturity; Morpho
    ///      PT-sUSDe/USDC market live with ~8.5M USDC available supply.
    uint256 constant FORK_BLOCK = 21_500_000;

    // ---- Pendle market (maturity-specific, hardcoded per family rules) ----
    /// @dev Pendle Market for PT/YT/SY-sUSDe-27MAR2025.
    ///      readTokens() -> (SY=0x3Ee118EF.., PT=0xE00bd3Df.., YT=0x96512230..)
    ///      Deployed at block ~20_768_225.
    address constant LOCAL_MARKET = 0xcDd26Eb5EB2Ce0f203a84553853667aE69Ca29Ce;

    // ---- Morpho market (PT-sUSDe-27MAR2025 / USDC, MEV Capital curated) ----
    /// @dev Linear-discount PT-sUSDe oracle (price() ~= 0.9514 USDC/PT at fork block).
    address constant MORPHO_ORACLE_PT_SUSDE = 0x9c0174fE7748F318dcB7300b93B170b6026280B0;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @dev 91.5% LLTV for PT-sUSDe-27MAR2025 collateral with linear-discount oracle.
    uint256 constant LLTV_91_5 = 0.915e18;

    // ---- Loop tuning ----
    uint256 constant EQUITY_USDE = 1_000_000e18; // 1M USDe (SY-sUSDe accepts USDe)
    uint256 constant LOOPS = 3;
    /// @dev Per-loop target LTV (under LLTV_91_5 with safety buffer).
    uint256 constant LOOP_LTV_BPS = 8500; // 85.00%

    // Curve USDe/USDC pool (coin0=USDe, coin1=USDC) - used to convert
    // borrowed USDC back to USDe for the PT-sUSDe buy loop.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    // ---- Local state ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(_pt);
        _trackToken(_sy);
        _trackToken(Mainnet.SUSDE);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.USDC,
            collateralToken: _pt,
            oracle: MORPHO_ORACLE_PT_SUSDE,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_91_5
        });
    }

    function testStrategy_F07_01() public {
        _fund(Mainnet.USDE, address(this), EQUITY_USDE);
        _startPnL();

        // Approvals
        IERC20(Mainnet.USDE).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        // ---- 1. Initial PT buy (USDe -> PT-sUSDe via Pendle) ----
        uint256 ptBought = _swapUsdeForPt(EQUITY_USDE, 0 /* minOut, slippage gated off-chain */);

        // ---- 2. Loop: supply PT, borrow USDC, buy more PT ----
        uint256 totalPt = ptBought;
        for (uint256 i = 0; i < LOOPS; i++) {
            // Supply this round's PT collateral.
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, IERC20(_pt).balanceOf(address(this)), address(this), "");

            // Compute headroom using the oracle price.
            // Morpho oracle price() returns:
            //   price * 1e(36 - collateral_dec + loan_dec) = price_USDC * 1e(36-18+6) = price_USDC * 1e24
            // So: collateral_value_USDC (1e6) = collateral_1e18 * ptPriceScaled / 1e36
            //   = (collateral_1e18 / 1e12) * ptPriceScaled / 1e24
            (bool ok, bytes memory data) = MORPHO_ORACLE_PT_SUSDE.staticcall(abi.encodeWithSignature("price()"));
            // Fallback to ~0.9514 USDC/PT if oracle call fails
            uint256 ptPriceScaled = ok && data.length == 32 ? abi.decode(data, (uint256)) : 951443981481481482000000;
            uint256 totalSupplied = _getCollateral();
            // collateral_value_USDC (6 dec) = collateral_1e18 * ptPriceScaled / 1e36
            uint256 collValueUSDC = (totalSupplied / 1e12) * ptPriceScaled / 1e24;
            uint256 borrowUSDC = (collValueUSDC * LOOP_LTV_BPS) / 10_000;
            // Subtract any previously borrowed amount.
            uint256 alreadyBorrowed = _getBorrowedAssets();
            if (borrowUSDC <= alreadyBorrowed) break;
            uint256 toBorrow = borrowUSDC - alreadyBorrowed;
            if (toBorrow < 1_000e6) break;

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrow, 0, address(this), address(this));

            // Convert borrowed USDC -> USDe via Curve (coin0=USDe, coin1=USDC).
            uint256 usdeOut = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
                int128(1), int128(0), toBorrow, 0
            );
            IERC20(Mainnet.USDE).approve(Mainnet.PENDLE_ROUTER_V4, usdeOut);

            // Buy more PT with freshly swapped USDe.
            uint256 newPt = _swapUsdeForPt(usdeOut, 0);
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
        emit log_named_uint("equity_usde_1e18", EQUITY_USDE);

        _endPnL("F07-01: PT-sUSDe cash-and-carry leveraged on Morpho");
    }

    // ---- Helpers ----

    /// @dev Swap USDe -> PT-sUSDe-27MAR2025 via Pendle Router V4.
    ///      SY-sUSDe accepts both USDe (0x4c9EDD5...) and sUSDe (0x9D39A5..).
    ///      At block 21_500_000 PT-sUSDe trades at ~0.9514 USDC/PT (~5% discount).
    ///      Expected PT out > input USDe * 1/0.9514 ~= 1.051x.
    ///      guessMax = usdeIn * 115/100 safely brackets the solution.
    function _swapUsdeForPt(uint256 usdeIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            // PT trades at ~5% discount -> PT out ~= USDe in / 0.95 ~= 1.05x USDe in.
            // 1.15x safely brackets the binary search without causing APPROX_EXHAUSTED.
            guessMax: usdeIn * 115 / 100,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15 // 0.1%
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.USDE,
            netTokenIn: usdeIn,
            tokenMintSy: Mainnet.USDE, // SY-sUSDe accepts USDe
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
