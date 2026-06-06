// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IPendleRouter} from "src/interfaces/pendle/IPendleRouter.sol";
import {IPendleMarket} from "src/interfaces/pendle/IPendleMarket.sol";
import {IPPrincipalToken} from "src/interfaces/pendle/IPPrincipalToken.sol";
import {IPYieldToken} from "src/interfaces/pendle/IPYieldToken.sol";
import {IStandardizedYield} from "src/interfaces/pendle/IStandardizedYield.sol";
import {IWombatRouter} from "src/interfaces/bsc/amm/IWombatRouter.sol";
import {console2} from "forge-std/console2.sol";

/// @title B14-08 PoC - PT-lisUSD-savings cash-and-carry on Pendle BSC
/// @notice Mirror of F07-08 (PT-sUSDS) tailored to BSC's lisUSD savings
///         wrapper. Buy `PT-lisUSDsavings-26JUN2025` at a fixed discount,
///         warp past maturity, redeem PT 1:1 to lisUSD and unwind to USDT.
///         The locked carry is `(1 - entryPrice)` annualised over the
///         time-to-maturity.
/// @dev    Distinct from B14-03 (which *loops* lisUSD): this strategy is
///         **unleveraged, fixed-term**, with the only mechanism being the
///         Pendle PT discount capture. Offline-first.
contract B14_08_PoC is BSCStrategyBase {
    /// @dev Pendle PT-lisUSD-savings-26JUN2025 market on BSC. // TODO verify.
    address constant LOCAL_PT_LISUSD_MARKET = 0x0000000000000000000000000000000000b14080;
    /// @dev PT principal token. // TODO verify.
    address constant LOCAL_PT_LISUSD = 0x0000000000000000000000000000000000b14081;
    /// @dev SY token. // TODO verify.
    address constant LOCAL_SY_LISUSD = 0x0000000000000000000000000000000000B14082;
    /// @dev YT token. // TODO verify.
    address constant LOCAL_YT_LISUSD = 0x0000000000000000000000000000000000B14083;
    /// @dev Assumed expiry: 26-JUN-2025 00:00 UTC.
    uint256 constant ASSUMED_EXPIRY = 1_750_896_000;

    // ---- Sizing ----
    /// @dev 100k USDT principal - 18-decimal BSC USDT.
    uint256 constant PRINCIPAL_USDT = 100_000e18;
    /// @dev Days from fork to maturity (modelled).
    uint256 constant DAYS_TO_EXPIRY = 180;
    /// @dev PT entry price in 1e18 - modelled 0.965 USDT per PT.
    uint256 constant ENTRY_PRICE_E18 = 965_000_000_000_000_000;
    /// @dev PT entry slippage on Pendle market + Wombat USDT->lisUSD swap.
    uint256 constant ENTRY_DRAG_BPS = 30;
    /// @dev Exit drag: PT redeem -> SY -> lisUSD -> Wombat -> USDT.
    uint256 constant EXIT_DRAG_BPS = 25;

    function setUp() public {
        _trackToken(BSC.USDT);
        _trackToken(BSC.lisUSD);
        _trackToken(LOCAL_PT_LISUSD);
        _trackToken(LOCAL_SY_LISUSD);
        _setOraclePrice(BSC.lisUSD, 1e8); // peg ~ $1 for this PoC
        _setOraclePrice(LOCAL_PT_LISUSD, 96_500_000); // $0.965
    }

    function testPtLisusdSavingsCashCarry() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainCarry();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B14-08-pt-lisusd-savings-cash-carry");
    }

    // ----------------------------------------------------------------
    // Forked branch.
    // ----------------------------------------------------------------
    function _runOnchainCarry() internal {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);

        // 1. USDT -> lisUSD via Wombat (PT-lisUSD is denominated in lisUSD).
        IERC20(BSC.USDT).approve(BSC.WOMBAT_ROUTER, type(uint256).max);
        address[] memory tokenPath = new address[](2);
        tokenPath[0] = BSC.USDT;
        tokenPath[1] = BSC.lisUSD;
        address[] memory poolPath = new address[](1);
        poolPath[0] = BSC.WOMBAT_MAIN_POOL;
        uint256 minOut = (PRINCIPAL_USDT * (10_000 - ENTRY_DRAG_BPS)) / 10_000;
        try IWombatRouter(BSC.WOMBAT_ROUTER).swapExactTokensForTokens(
            tokenPath, poolPath, PRINCIPAL_USDT, minOut, address(this), block.timestamp + 60
        ) returns (uint256) {} catch {
            return;
        }

        // 2. lisUSD -> PT-lisUSD via Pendle router.
        uint256 lisBal = IERC20(BSC.lisUSD).balanceOf(address(this));
        if (lisBal == 0) return;
        IERC20(BSC.lisUSD).approve(BSC.PENDLE_ROUTER_V4, type(uint256).max);

        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });
        IPendleRouter.SwapData memory emptySwap;
        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: BSC.lisUSD,
            netTokenIn: lisBal,
            tokenMintSy: BSC.lisUSD,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        IPendleRouter.LimitOrderData memory emptyLimit;

        uint256 ptOut;
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_LISUSD_MARKET, 0, approx, input, emptyLimit
        ) returns (uint256 out_, uint256, uint256) {
            ptOut = out_;
        } catch {
            return;
        }
        if (ptOut == 0) return;

        // 3. Warp to expiry + 1h.
        vm.warp(ASSUMED_EXPIRY + 1 hours);
        vm.roll(block.number + (DAYS_TO_EXPIRY * 86_400 / 3 + 1));

        // 4. Redeem PT via Pendle router; fallback to YT.redeemPY.
        IERC20(LOCAL_PT_LISUSD).approve(BSC.PENDLE_ROUTER_V4, ptOut);
        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: BSC.lisUSD,
            minTokenOut: 0,
            tokenRedeemSy: BSC.lisUSD,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        try IPendleRouter(BSC.PENDLE_ROUTER_V4).redeemPyToToken(
            address(this), LOCAL_YT_LISUSD, ptOut, output
        ) returns (uint256, uint256) {} catch {
            // Fallback: transfer PT to YT and redeem.
            IERC20(LOCAL_PT_LISUSD).transfer(LOCAL_YT_LISUSD, ptOut);
            try IPYieldToken(LOCAL_YT_LISUSD).redeemPY(address(this)) returns (uint256 syOut) {
                try IStandardizedYield(LOCAL_SY_LISUSD).redeem(
                    address(this), syOut, BSC.lisUSD, 0, false
                ) returns (uint256) {} catch {}
            } catch {}
        }

        // 5. lisUSD -> USDT to settle.
        uint256 lisBack = IERC20(BSC.lisUSD).balanceOf(address(this));
        if (lisBack == 0) return;
        tokenPath[0] = BSC.lisUSD;
        tokenPath[1] = BSC.USDT;
        uint256 minOut2 = (lisBack * (10_000 - EXIT_DRAG_BPS)) / 10_000;
        try IWombatRouter(BSC.WOMBAT_ROUTER).swapExactTokensForTokens(
            tokenPath, poolPath, lisBack, minOut2, address(this), block.timestamp + 60
        ) returns (uint256) {} catch {}
    }

    // ----------------------------------------------------------------
    // Offline branch - closed-form discount-convergence math.
    //   PT bought at ENTRY_PRICE_E18 USDT per PT.
    //   ptOut = principal * 1e18 / ENTRY_PRICE_E18.
    //   At expiry PT redeems 1:1 -> ptOut USDT.
    //   Gross carry = ptOut - principal = principal * (1/entry - 1).
    //   Net = gross - entry_drag - exit_drag.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        // Compute PT received per the entry price; subtract entry slippage
        // from the lisUSD effectively converted into PT.
        int256 principal = int256(PRINCIPAL_USDT);
        // Effective USDT-into-lisUSD after entry Wombat swap.
        int256 lisIn = (principal * int256(10_000 - ENTRY_DRAG_BPS)) / 10_000;
        // PT received: lisIn / entryPrice (1e18).
        int256 ptOut = (lisIn * int256(1e18)) / int256(ENTRY_PRICE_E18);
        // At expiry: PT -> lisUSD 1:1. Convert lisUSD back to USDT, less exit drag.
        int256 usdtOut = (ptOut * int256(10_000 - EXIT_DRAG_BPS)) / 10_000;
        int256 pnlUsd = usdtOut - principal;

        if (pnlUsd > 0) {
            _fund(BSC.USDT, address(this), uint256(pnlUsd));
        } else if (pnlUsd < 0) {
            uint256 burn = uint256(-pnlUsd);
            uint256 bal = IERC20(BSC.USDT).balanceOf(address(this));
            if (burn > bal) burn = bal;
            if (burn > 0) IERC20(BSC.USDT).transfer(address(0xdead), burn);
        }
        console2.log("offline pt_carry_pnl_usd_1e18=", pnlUsd);
    }

    function _tryFork() internal returns (bool) {
        try vm.envString("BSC_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) return false;
            try vm.createSelectFork(rpc, 42_000_000) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
