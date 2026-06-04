// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @title F07-05 - PT-rsETH leveraged buy on Morpho (Kelp + Pendle + Morpho, 3-mech)
///
/// @notice 3-mechanism stack:
///         1. Kelp DAO rsETH = ETH-denominated LRT receipt; rsETH/ETH appreciates
///            with EigenLayer + native restaking yield.
///         2. Pendle PT-rsETH splits the implied LRT-staking yield into a fixed-
///            discount zero-coupon claim on 1 rsETH at maturity.
///         3. Morpho Blue PT-rsETH/WETH isolated market (PendleSparkLinearDiscount
///            oracle) lets the PT be levered against WETH borrows up to 86% LLTV
///            without being mark-to-market liquidated by AMM spot wobble.
///
///         Strategy: buy PT-rsETH with WETH, post as Morpho collateral, borrow
///         WETH, buy more PT, loop. Captures rsETH implied fixed APY * leverage
///         minus WETH borrow cost.
contract F07_05_PtRsethMorphoKelpLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Mid-Aug 2024. PT-rsETH-26DEC2024 has ~4 months to maturity; Morpho
    ///      PT-rsETH/WETH market live with WETH supply available; Kelp's rsETH
    ///      NAV is appreciating cleanly.
    uint256 constant FORK_BLOCK = 20_650_000;

    // ---- Pendle market (PT/YT/SY-rsETH-26DEC2024) ----
    /// @dev Pendle Market for PT/YT/SY-rsETH-26DEC2024.
    ///      Maturity: 26 December 2024 (1735171200 UTC).
    ///      Source: Pendle markets registry (rsETH 26-Dec-2024 ETH variant).
    address constant LOCAL_MARKET = 0x6b4740722e46048874d84306B2877600ABCea3Ae;

    // ---- Morpho market (PT-rsETH-26DEC2024 / WETH) ----
    /// @dev PendleSparkLinearDiscount oracle for PT-rsETH-26DEC2024 vs WETH.
    address constant MORPHO_ORACLE_PT_RSETH = 0xec4d7a9d0bD7EA8DD45d9eD20a4dd6C4E00D5d8a;
    /// @dev Morpho Blue AdaptiveCurveIRM (shared singleton).
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @dev 86% LLTV variant for PT-rsETH/WETH market.
    uint256 constant LLTV_86 = 0.86e18;

    // ---- Loop tuning ----
    uint256 constant EQUITY_WETH = 100 ether;
    uint256 constant LOOPS = 4;
    /// @dev Per-loop LTV target (safety margin under 86% LLTV).
    uint256 constant LOOP_LTV_BPS = 8200; // 82%

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.RSETH);
        _trackToken(_pt);
        _trackToken(_sy);

        _market = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: _pt,
            oracle: MORPHO_ORACLE_PT_RSETH,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });
    }

    function testStrategy_F07_05() public {
        // SKIP: The Morpho oracle for PT-rsETH/WETH (0xec4d7a9d...) was never
        // deployed on mainnet. No WETH/PT-rsETH Morpho market exists (verified
        // against morpho_markets.tsv and on-chain calls). The SY-rsETH contract
        // does not accept WETH as tokenMintSy (only rsETH, ETH, stETH, etc).
        // Strategy cannot execute without a genuine PT-rsETH Morpho market.
        vm.skip(true);
        _fund(Mainnet.WETH, address(this), EQUITY_WETH);
        _startPnL();

        IERC20(Mainnet.WETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(_pt).approve(Mainnet.MORPHO, type(uint256).max);

        // ---- 1. Initial PT-rsETH buy via Pendle V4 ----
        _swapWethForPt(EQUITY_WETH, 0);

        // ---- 2. Loop: supply PT -> borrow WETH -> buy more PT ----
        for (uint256 i = 0; i < LOOPS; i++) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(
                _market, IERC20(_pt).balanceOf(address(this)), address(this), ""
            );

            // PT-rsETH priced ~0.955 WETH/PT (18-dec each). Live use should call
            // _market.oracle.price() and convert through Morpho's SCALE_FACTOR.
            uint256 collTotal = _getCollateral();
            uint256 collValueWeth = (collTotal * 955) / 1000;
            uint256 wantDebt = (collValueWeth * LOOP_LTV_BPS) / 10_000;
            uint256 already = _getBorrowedAssets();
            if (wantDebt <= already) break;
            uint256 toBorrow = wantDebt - already;
            if (toBorrow < 0.01 ether) break;

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrow, 0, address(this), address(this));
            _swapWethForPt(toBorrow, 0);
        }

        // Final supply to lock max leverage.
        uint256 trailing = IERC20(_pt).balanceOf(address(this));
        if (trailing > 0) {
            IMorpho(Mainnet.MORPHO).supplyCollateral(_market, trailing, address(this), "");
        }

        emit log_named_uint("pt_collateral_1e18", _getCollateral());
        emit log_named_uint("weth_debt_1e18", _getBorrowedAssets());
        emit log_named_uint("equity_weth_1e18", EQUITY_WETH);

        _endPnL("F07-05: PT-rsETH leveraged on Morpho (Kelp + Pendle + Morpho)");
    }

    // ---- Helpers ----

    function _swapWethForPt(uint256 wethIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WETH,
            netTokenIn: wethIn,
            // SY-rsETH accepts WETH, ETH, rsETH (via Kelp deposit) as tokensIn.
            tokenMintSy: Mainnet.WETH,
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
        return (uint256(p.borrowShares) * m.totalBorrowAssets) / m.totalBorrowShares;
    }
}
