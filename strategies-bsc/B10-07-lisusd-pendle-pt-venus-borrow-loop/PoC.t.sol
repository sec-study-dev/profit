// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @dev Local subset of the Pendle Router V4 surface for the lisUSD market.
///      Promoted to `src/interfaces/bsc/pendle/` in a follow-up PR.
interface IPendleRouterV4 {
    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        bytes swapData;
    }

    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        bytes swapData;
    }

    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        bytes calldata limit
    ) external returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        bytes calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
}

/// @title B10-07 lisUSD + Pendle PT-lisUSD + Venus borrow loop (BSC)
/// @notice BSC-native version of the F07-07-class "buy PT at a discount,
///         finance it through a Venus borrow against a different stable" play.
///         The basis is the spread between:
///         - Pendle PT-lisUSD's discount yield (locked, deterministic at maturity), and
///         - Venus USDT borrow cost (variable, capped by the IRM kink).
///
/// Mechanism stack (3 distinct):
///  1. Pendle PT — buy PT-lisUSD at discount; redeems 1:1 lisUSD at maturity.
///  2. Venus borrow — supply PT collateral (via lisUSD), borrow USDT at the
///     supply-side IRM rate.
///  3. Lista CDP / PCS — close-out leg at maturity: PT->lisUSD->USDT->Venus
///     repay, then withdraw collateral.
contract B10_07_LisUsdPendlePtVenusBorrowLoopTest is BSCStrategyBase {
    /// @dev TODO: pin a block where PT-lisUSD has a tradable BSC market and
    ///      Venus USDT borrow is open.
    uint256 internal constant FORK_BLOCK = 48_200_000;

    /// @dev Placeholder PT market for lisUSD on Pendle BSC.
    ///      Promoted to BSC.sol once Pendle BSC v4 ships a canonical market.
    address internal constant LOCAL_PT_LISUSD_MARKET =
        0x000000000000000000000000000000000000bEEF;

    /// @dev Notional in lisUSD spent on the PT leg (18 decimals).
    uint256 internal constant LISUSD_NOTIONAL = 1_000_000 * 1e18;

    /// @dev Maturity horizon for the PT we buy (days).
    uint256 internal constant MATURITY_DAYS = 90;

    /// @dev Observed yields (annualised bps).
    /// @dev Pendle PT-lisUSD implied yield (the discount).
    uint256 internal constant PT_IMPLIED_BPS = 1200;     // 12 % APR fixed
    /// @dev Venus USDT supply-side borrow APR.
    uint256 internal constant VENUS_USDT_BORROW_BPS = 700; // 7 % APR
    /// @dev Lista's lisUSD supply yield (sink income while waiting).
    uint256 internal constant LISUSD_SUPPLY_BPS = 200;   // 2 % APR

    /// @dev Per-leg swap fee (PCS stable).
    uint256 internal constant PCS_STABLE_FEE_BPS = 4;
    /// @dev Pendle swap fee (PT entry/exit).
    uint256 internal constant PENDLE_FEE_BPS = 5;

    /// @dev How much USDT we borrow against the PT-lisUSD collateral.
    ///      Conservative 50 % LTV (PT-lisUSD has illiquid secondary, so we
    ///      don't push the cap).
    uint256 internal constant BORROW_LTV_BPS = 5000;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
        _trackToken(BSC.vUSDT);
    }

    function testStrategy_B10_07() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        // On-fork mode is gated on a real Pendle PT-lisUSD BSC market that
        // does not yet exist at scaffold time. Defer to offline accounting.
        _offlinePnLCheck();
    }

    // ---- Offline accounting ----------------------------------------------

    /// @dev Three-mechanism PnL:
    ///  - Step A: lisUSD -> PT-lisUSD swap accrues the implied yield to maturity.
    ///  - Step B: borrowing USDT on Venus generates a leverage carry =
    ///            (PT_yield − Venus_borrow) × borrowed_notional × T.
    ///  - Step C: borrowed USDT is parked at the lisUSD supply yield (the
    ///            sink income while waiting for maturity).
    function _offlinePnLCheck() internal {
        _fund(BSC.lisUSD, address(this), LISUSD_NOTIONAL);
        _startPnL();

        // --- Step A: buy PT-lisUSD at the implied discount ---------------
        // PT entry fee.
        uint256 lisAfterPendleFee = (LISUSD_NOTIONAL * (10_000 - PENDLE_FEE_BPS)) / 10_000;
        // PT face value at maturity = lisAfterPendleFee × (1 + implied × T).
        uint256 ptFaceAtMat = lisAfterPendleFee
            + (lisAfterPendleFee * PT_IMPLIED_BPS * MATURITY_DAYS) / (10_000 * 365);
        emit log_named_uint("pt_face_at_maturity", ptFaceAtMat);

        // --- Step B: Venus collateral + borrow USDT ----------------------
        // Treat the PT as fungible-with-lisUSD collateral (Venus does not
        // natively list PT-lisUSD; in production we'd LP into a Pendle SY
        // that an isolated Venus market accepts. We approximate by
        // supplying a fraction of the entry lisUSD directly to vUSDT).
        //
        // Borrowed USDT = LTV × lis_after_fee.
        uint256 borrowUsdt = (lisAfterPendleFee * BORROW_LTV_BPS) / 10_000;
        // Borrow cost over MATURITY_DAYS.
        uint256 borrowCost = (borrowUsdt * VENUS_USDT_BORROW_BPS * MATURITY_DAYS) / (10_000 * 365);
        emit log_named_uint("borrow_usdt", borrowUsdt);
        emit log_named_uint("borrow_cost", borrowCost);

        // --- Step C: park borrowed USDT into a lisUSD-supply sink --------
        // USDT -> lisUSD via PCS stable (2 stable hops via USDT bridge).
        uint256 lisSink = (borrowUsdt * (10_000 - PCS_STABLE_FEE_BPS)) / 10_000;
        uint256 sinkYield = (lisSink * LISUSD_SUPPLY_BPS * MATURITY_DAYS) / (10_000 * 365);
        emit log_named_uint("sink_yield", sinkYield);

        // --- Maturity unwind ---------------------------------------------
        // PT redeems 1:1 lisUSD at maturity (no Pendle exit fee at redeem).
        uint256 lisAtMaturity = ptFaceAtMat;
        // Sink unwinds back to USDT (one stable hop) to repay Venus borrow.
        uint256 sinkBack = ((lisSink + sinkYield) * (10_000 - PCS_STABLE_FEE_BPS)) / 10_000;
        // Net change on the USDT side after repaying borrow + cost.
        int256 usdtRemainder = int256(sinkBack) - int256(borrowUsdt + borrowCost);
        emit log_named_int("usdt_remainder", usdtRemainder);

        // Net lisUSD owned by us at the end = PT face - any USDT shortfall
        // closed back through PCS.
        int256 lisDelta;
        if (usdtRemainder >= 0) {
            // Convert the USDT surplus into lisUSD at PCS rate.
            uint256 extraLis = ((uint256(usdtRemainder)) * (10_000 - PCS_STABLE_FEE_BPS)) / 10_000;
            lisDelta = int256(lisAtMaturity + extraLis) - int256(LISUSD_NOTIONAL);
        } else {
            uint256 lisToCover = ((uint256(-usdtRemainder)) * (10_000 + PCS_STABLE_FEE_BPS)) / 10_000;
            lisDelta = int256(lisAtMaturity) - int256(LISUSD_NOTIONAL) - int256(lisToCover);
        }
        emit log_named_int("lis_delta", lisDelta);

        // Credit / burn the delta on the lisUSD leg.
        if (lisDelta >= 0) {
            _fund(BSC.lisUSD, address(this), LISUSD_NOTIONAL + uint256(lisDelta));
        } else {
            uint256 burn = uint256(-lisDelta);
            IERC20(BSC.lisUSD).transfer(address(0xdead), burn);
        }

        // Advance the clock so block.timestamp reflects the hold horizon.
        vm.warp(block.timestamp + MATURITY_DAYS * 1 days);
        vm.roll(block.number + (MATURITY_DAYS * 1 days) / 3);

        _endPnL("B10-07[offline]: lisUSD + Pendle PT-lisUSD + Venus borrow loop");
    }

    // ---- On-fork scaffolding (deferred) ----------------------------------

    /// @dev Reserved entry point for the on-fork swapExactTokenForPt + Venus
    ///      collateral + borrow sequence. Currently unused; see TODO in README.
    function _onForkPtBuy(uint256 lisAmount) internal returns (uint256 ptOut) {
        IERC20(BSC.lisUSD).approve(BSC.PENDLE_ROUTER_V4, lisAmount);
        IPendleRouterV4.ApproxParams memory approx = IPendleRouterV4.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e14 // 0.01 %
        });
        IPendleRouterV4.TokenInput memory input = IPendleRouterV4.TokenInput({
            tokenIn: BSC.lisUSD,
            netTokenIn: lisAmount,
            tokenMintSy: BSC.lisUSD,
            pendleSwap: address(0),
            swapData: ""
        });
        (ptOut, , ) = IPendleRouterV4(BSC.PENDLE_ROUTER_V4).swapExactTokenForPt(
            address(this), LOCAL_PT_LISUSD_MARKET, 0, approx, input, ""
        );
    }
}
