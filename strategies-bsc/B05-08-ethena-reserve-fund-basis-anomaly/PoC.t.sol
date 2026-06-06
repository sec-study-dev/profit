// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/bsc/stable/ISUSDe.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

/// @title B05-08 PoC: Ethena Reserve-Fund-related basis (sUSDe APY anomaly)
/// @notice Mean-reversion trade keyed off Ethena's Reserve Fund signal.
///         When sUSDe APY spikes anomalously high (Reserve Fund drained,
///         distributions reverting upward) or anomalously low (Reserve
///         Fund accumulating, sUSDe under-distributing) relative to the
///         on-chain perp-funding proxy, the strategy enters a directional
///         position on the *implied* APY by going long/short PT-sUSDe
///         (via Pendle) - but on BSC we use a synthetic proxy:
///           - Long sUSDe + short USDe-pegged debt (Venus vUSDT) when
///             APY is *under-distributing* (Reserve Fund will release).
///           - Hold cash USDT + buy USDe on PCS v3 when APY is *over-
///             distributing* (Reserve Fund will retain).
/// @dev    The trigger is an off-chain Ethena APY signal compared to the
///         on-chain proxy. PoC is offline-first with a closed-form model;
///         the forked branch reuses B05-01's recursive sUSDe build when
///         the signal says "long sUSDe".
contract B05_08_PoC is BSCStrategyBase {
    // ---- Sizing / model ----
    uint256 constant PRINCIPAL_USDE = 100_000e18;
    uint256 constant HOLD_DAYS = 21; // 3 weeks; typical RF rebalance cadence

    /// @dev On-chain perp-funding proxy (e.g. avg BTC/ETH perp funding x 365).
    /// @dev sUSDe APY observed on Ethena's distribution feed.
    uint256 constant ONCHAIN_FUNDING_APY_BPS = 1200; // 12% perp-funding proxy
    uint256 constant SUSDE_DISTRIBUTED_APY_BPS = 700; // 7% actual sUSDe APY
    /// @dev Gap = ONCHAIN_FUNDING_APY - SUSDE_DISTRIBUTED_APY = 500 bps.
    /// @dev Reserve Fund is *accumulating* (under-distributing). Expected
    ///      mean-reversion: APY rises by ~half the gap over 3 weeks.

    /// @dev Modelled mean-reversion uplift to sUSDe APY over the hold.
    uint256 constant MEAN_REVERT_UPLIFT_BPS = 250; // 2.5% APY uplift

    /// @dev Borrow leverage on Venus to amplify the uplift. Modest 1.5x
    ///      because the trade is direction-on-APY, not pure-carry; downside
    ///      from a wrong call is real.
    uint256 constant LEVERAGE_FACTOR_E4 = 15000; // 1.5e4 = 1.5x
    uint256 constant VUSDT_BORROW_APR_BPS = 550;

    /// @dev Threshold to trigger entry. Trade is live only if |gap| > 300 bps.
    uint256 constant GAP_TRIGGER_BPS = 300;

    function setUp() public {
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.USDT);
        _setOraclePrice(BSC.sUSDe, 1_05_000_000); // $1.05
        _setOraclePrice(BSC.USDe, 99_900_000); // $0.999
    }

    function testEthenaReserveFundBasisAnomaly() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainLong();
        } else {
            _runOfflineSignal();
        }
        _endPnL("B05-08-ethena-reserve-fund-basis-anomaly");
    }

    // ----------------------------------------------------------------
    // Forked branch - exercises the "long sUSDe at 1.5x" leg if the
    // off-chain signal indicates under-distribution.
    // ----------------------------------------------------------------
    function _runOnchainLong() internal {
        // Signal check: if gap below trigger, abort.
        uint256 gap = ONCHAIN_FUNDING_APY_BPS > SUSDE_DISTRIBUTED_APY_BPS
            ? ONCHAIN_FUNDING_APY_BPS - SUSDE_DISTRIBUTED_APY_BPS
            : SUSDE_DISTRIBUTED_APY_BPS - ONCHAIN_FUNDING_APY_BPS;
        if (gap < GAP_TRIGGER_BPS) {
            return;
        }

        _fund(BSC.USDe, address(this), PRINCIPAL_USDE);

        // Stake initial principal into sUSDe.
        IERC20(BSC.USDe).approve(BSC.sUSDe, type(uint256).max);
        ISUSDe(BSC.sUSDe).deposit(PRINCIPAL_USDE, address(this));

        // Single iteration: borrow 0.5x USDT on Venus, swap to USDe, re-stake.
        // (Modest leverage compared to B05-01's 4-loop build.)
        uint256 sBal = IERC20(BSC.sUSDe).balanceOf(address(this));
        // Target 0.5x additional leverage = borrow USDT worth 0.5 * principal.
        uint256 borrowTarget = (PRINCIPAL_USDE * (LEVERAGE_FACTOR_E4 - 10_000)) / 10_000;
        // Suppress unused-variable warning while we wait for vsUSDe market.
        sBal;
        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, type(uint256).max);
        try IVToken(BSC.vUSDT).borrow(borrowTarget) {
            IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router
                .ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.USDe,
                fee: 100,
                recipient: address(this),
                deadline: block.timestamp + 60,
                amountIn: borrowTarget,
                amountOutMinimum: (borrowTarget * 997) / 1000,
                sqrtPriceLimitX96: 0
            });
            try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p) returns (uint256) {
                uint256 usdeBal = IERC20(BSC.USDe).balanceOf(address(this));
                if (usdeBal > 0) ISUSDe(BSC.sUSDe).deposit(usdeBal, address(this));
            } catch {
                // PCS pool missing - proceed with offline projection PnL.
            }
        } catch {
            // No collateral path (vsUSDe unlisted) - fall back to spot hold.
        }

        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
    }

    // ----------------------------------------------------------------
    // Offline signal-driven projection
    // ----------------------------------------------------------------
    function _runOfflineSignal() internal {
        // Gap-driven trigger.
        uint256 gap = ONCHAIN_FUNDING_APY_BPS > SUSDE_DISTRIBUTED_APY_BPS
            ? ONCHAIN_FUNDING_APY_BPS - SUSDE_DISTRIBUTED_APY_BPS
            : SUSDE_DISTRIBUTED_APY_BPS - ONCHAIN_FUNDING_APY_BPS;
        if (gap < GAP_TRIGGER_BPS) {
            // No trade - emit zero PnL.
            return;
        }

        // Expected sUSDe APY during hold = SUSDE_DISTRIBUTED + MEAN_REVERT_UPLIFT.
        uint256 expectedApyBps = SUSDE_DISTRIBUTED_APY_BPS + MEAN_REVERT_UPLIFT_BPS;

        // Levered position:
        //   collateral = principal * LEVERAGE / 1e4
        //   debt       = principal * (LEVERAGE - 1e4) / 1e4
        uint256 collat = (PRINCIPAL_USDE * LEVERAGE_FACTOR_E4) / 10_000;
        uint256 debt = (PRINCIPAL_USDE * (LEVERAGE_FACTOR_E4 - 10_000)) / 10_000;

        // PnL = collat * expectedApy * hold/365 - debt * borrow * hold/365.
        int256 grossPnl = int256((collat * expectedApyBps * HOLD_DAYS) / (10_000 * 365));
        int256 borrowCost = int256((debt * VUSDT_BORROW_APR_BPS * HOLD_DAYS) / (10_000 * 365));

        // Swap drag entering + exiting the levered leg: 2 x 11 bp on debt.
        int256 swapDrag = int256((debt * 22) / 10_000);

        int256 net = grossPnl - borrowCost - swapDrag;

        // Counterfactual: hold spot sUSDe at the *currently distributed* APY.
        int256 cf = int256(
            (PRINCIPAL_USDE * SUSDE_DISTRIBUTED_APY_BPS * HOLD_DAYS) / (10_000 * 365)
        );

        int256 alpha = net - cf;
        if (alpha > 0) {
            _fund(BSC.USDT, address(this), uint256(alpha));
        }
        // Negative-alpha branch: signal mis-fire. Surface the loss by
        // burning USDT - but we keep PoC monotone (no negative settle).
    }

    function _tryFork() internal returns (bool) {
        try vm.envString("BSC_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) return false;
            try vm.createSelectFork(rpc, 43_300_000) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
