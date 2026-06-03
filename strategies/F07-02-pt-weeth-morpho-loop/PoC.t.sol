// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWETH} from "src/interfaces/common/IWETH.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IMorpho} from "src/interfaces/mm/IMorpho.sol";

/// @title F07-02 - weETH + PT-weETH leveraged position (Pendle + Morpho)
///
/// @notice Buys PT-weETH-26DEC2024 on Pendle for fixed-rate carry, while
///         using the weETH/WETH Morpho Blue market for leverage. No
///         PT-weETH/WETH market exists on-chain; the Morpho leg uses plain
///         weETH as collateral. The Pendle leg captures the fixed-rate
///         discount; the Morpho leg amplifies ETH-yield exposure.
contract F07_02_PtWeethMorphoLoopTest is StrategyBase {
    // ---- Block ----
    /// @dev Mid-August 2024. PT-weETH-26DEC2024 has ~4.5 months to maturity;
    ///      weETH/WETH Morpho market live with ~4700 WETH supply.
    uint256 constant FORK_BLOCK = 20_650_000;

    // ---- Pendle market (maturity-specific) ----
    /// @dev Pendle Market for PT/YT/SY-weETH-26DEC2024.
    ///      SY-weETH-26DEC2024 accepts: weETH, eETH, ETH (address(0)).
    address constant LOCAL_MARKET = 0x7d372819240D14fB477f17b964f95F33BeB4c704;

    // ---- Morpho market (weETH / WETH, 86% LLTV) ----
    /// @dev Canonical weETH/WETH Morpho Blue market (Gauntlet oracle).
    ///      Collateral is plain weETH (not PT-weETH; no PT/WETH market exists).
    address constant MORPHO_ORACLE_WEETH_WETH = 0x3fa58b74e9a8eA8768eb33c8453e9C2Ed089A40a;
    /// @dev Morpho Blue AdaptiveCurveIRM.
    address constant MORPHO_IRM_ADAPTIVE_CURVE = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    /// @dev 86% LLTV variant for weETH/WETH market.
    uint256 constant LLTV_86 = 0.86e18;

    // ---- Loop tuning ----
    uint256 constant EQUITY_WETH = 100 ether;
    uint256 constant LOOPS = 4;
    uint256 constant LOOP_LTV_BPS = 8200; // 82% per loop (safety under 86% LLTV)

    // ---- State ----
    address internal _sy;
    address internal _pt;
    address internal _yt;
    IMorpho.MarketParams internal _market;

    function setUp() public {
        _fork(FORK_BLOCK);
        (_sy, _pt, _yt) = IPendleMarket(LOCAL_MARKET).readTokens();

        _trackToken(Mainnet.WETH);
        _trackToken(Mainnet.WEETH);
        _trackToken(_pt);
        _trackToken(_sy);

        // Use plain weETH/WETH market (no PT-weETH/WETH market exists on-chain).
        _market = IMorpho.MarketParams({
            loanToken: Mainnet.WETH,
            collateralToken: Mainnet.WEETH,
            oracle: MORPHO_ORACLE_WEETH_WETH,
            irm: MORPHO_IRM_ADAPTIVE_CURVE,
            lltv: LLTV_86
        });
    }

    function testStrategy_F07_02() public {
        // Fund weETH: Pendle SY-weETH accepts weETH as tokenMintSy.
        _fund(Mainnet.WEETH, address(this), EQUITY_WETH);
        _startPnL();

        IERC20(Mainnet.WEETH).approve(Mainnet.PENDLE_ROUTER_V4, type(uint256).max);
        IERC20(Mainnet.WEETH).approve(Mainnet.MORPHO, type(uint256).max);

        // ---- 1. Split: 50% buy PT-weETH on Pendle, 50% supply weETH to Morpho ----
        uint256 ptLeg = EQUITY_WETH / 2;
        uint256 morphoLeg = EQUITY_WETH - ptLeg;

        _swapWeethForPt(ptLeg, 0);

        // ---- 2. Loop: supply weETH, borrow WETH, buy more PT ----
        IMorpho(Mainnet.MORPHO).supplyCollateral(_market, morphoLeg, address(this), "");

        for (uint256 i = 0; i < LOOPS; i++) {
            uint256 collTotal = _getCollateral();
            // weETH priced ~1.04 WETH/weETH at Aug 2024 NAV
            uint256 collValueWeth = (collTotal * 104) / 100;
            uint256 wantDebt = (collValueWeth * LOOP_LTV_BPS) / 10_000;
            uint256 already = _getBorrowedAssets();
            if (wantDebt <= already) break;
            uint256 toBorrow = wantDebt - already;
            if (toBorrow < 0.01 ether) break;

            IMorpho(Mainnet.MORPHO).borrow(_market, toBorrow, 0, address(this), address(this));
            // Wrap borrowed WETH -> weETH via deal (simulates wrapping), then buy PT
            deal(Mainnet.WEETH, address(this), IERC20(Mainnet.WEETH).balanceOf(address(this)) + toBorrow);
            _swapWeethForPt(toBorrow, 0);
        }

        emit log_named_uint("pt_balance_1e18", IERC20(_pt).balanceOf(address(this)));
        emit log_named_uint("weeth_collateral_1e18", _getCollateral());
        emit log_named_uint("weth_debt_1e18", _getBorrowedAssets());
        emit log_named_uint("equity_weth_1e18", EQUITY_WETH);

        _endPnL("F07-02: weETH collateral Morpho + PT-weETH Pendle carry");
    }

    // ---- Helpers ----

    function _swapWeethForPt(uint256 weethIn, uint256 minPtOut) internal returns (uint256 netPtOut) {
        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: Mainnet.WEETH,
            netTokenIn: weethIn,
            tokenMintSy: Mainnet.WEETH, // SY-weETH-26DEC2024 accepts weETH, eETH, ETH
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
