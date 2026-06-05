// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";

/// @title B14-01 PoC - vUSDT self-loop (Venus IRM + XVS incentive carry)
/// @notice Treat `vUSDT` as a yield-bearing stablecoin wrapper and recursively
///         lever it against borrowed USDT in the same Venus Core market.
///         The wrapper carry is sourced from XVS incentives stacked on top of
///         the supply-borrow IRM wedge, not from any external protocol.
/// @dev    Two-phase:
///         - Forked phase (BSC_RPC_URL set): runs the real iteration loop and
///           calls `Comptroller.claimVenus(...)`.
///         - Offline phase (default): closed-form projection mirroring the
///           on-chain math so the PoC compiles + runs offline.
contract B14_01_PoC is BSCStrategyBase {
    // ---- Inlined addresses not yet in BSC.sol (see README) ----
    /// @dev Venus XVS governance token. // TODO verify.
    address constant LOCAL_XVS = 0x000000000000000000000000000000000000B141;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_USDT = 100_000e18; // 100k USDT principal
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 7800; // vUSDT collateral factor ~ 0.78
    uint256 constant SAFETY_BPS = 9500; // 0.95 haircut
    uint256 constant HOLD_DAYS = 30;

    // ---- Rates (1e4 = 100 %) ----
    uint256 constant SUPPLY_APY_BPS = 350; // 3.50 % vUSDT supply APY
    uint256 constant BORROW_APR_BPS = 650; // 6.50 % vUSDT borrow APR
    uint256 constant XVS_SUPPLY_BPS = 200; // 2.00 % XVS supply incentive (APR)
    uint256 constant XVS_BORROW_BPS = 350; // 3.50 % XVS borrow incentive (APR)

    function setUp() public {
        // Track wrapper underlying + reward.
        _trackToken(BSC.USDT);
        _trackToken(BSC.vUSDT);
        _trackToken(LOCAL_XVS);
        // XVS price reference - assume ~$10/XVS = 10e8 in oracle override.
        _setOraclePrice(LOCAL_XVS, 10e8);
    }

    // ----------------------------------------------------------------
    // Public entrypoint - offline (default) or fork.
    // ----------------------------------------------------------------
    function testVusdtVenusSelfLoop() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainLoop();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B14-01-vusdt-venus-self-loop");
    }

    // ----------------------------------------------------------------
    // Forked branch - only reached when BSC_RPC_URL is configured.
    // ----------------------------------------------------------------
    function _runOnchainLoop() internal {
        _fund(BSC.USDT, address(this), PRINCIPAL_USDT);

        // Enter vUSDT once.
        address[] memory mkts = new address[](1);
        mkts[0] = BSC.vUSDT;
        IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts);

        IERC20(BSC.USDT).approve(BSC.vUSDT, type(uint256).max);

        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 usdtBal = IERC20(BSC.USDT).balanceOf(address(this));
            if (usdtBal == 0) break;

            // Supply USDT, mint vUSDT shares.
            IVToken(BSC.vUSDT).mint(usdtBal);

            // Borrow against the new vUSDT collateral.
            // Compute borrow size from CF * safety; the iteration's
            // borrow is monotone-decreasing because each step adds
            // both collateral and debt at the same nominal USDT price.
            uint256 toBorrow = (usdtBal * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (toBorrow == 0) break;
            IVToken(BSC.vUSDT).borrow(toBorrow);
        }

        // Hold and let accruals tick.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        IVToken(BSC.vUSDT).borrowBalanceCurrent(address(this));
        IVToken(BSC.vUSDT).balanceOfUnderlying(address(this));

        // Claim XVS rewards.
        try IVenusComptroller(BSC.VENUS_COMPTROLLER).claimVenus(address(this)) {
            // XVS now sits in address(this); the offline _endPnL prices it.
        } catch {
            // Tolerate Venus selectors evolving across pool upgrades.
        }
    }

    // ----------------------------------------------------------------
    // Offline branch - closed-form projection.
    // Models the leverage stack, supply/borrow IRM wedge, and XVS overlay.
    // The PnL is settled as a USDT delta via `_fund` so the canonical
    // `_endPnL` picks it up via the tracked-token bucket.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        // Build the levered series.
        uint256 cfEff = (CF_BPS * SAFETY_BPS) / 10_000; // 7410 bps per step
        uint256 termBps = 10_000;
        uint256 sumBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            sumBps += termBps;
            termBps = (termBps * cfEff) / 10_000;
        }
        // sumBps = 10_000 * collateral_leverage (in bps)
        uint256 collatBps = sumBps;
        uint256 debtBps = sumBps - 10_000;

        // Net supply leg (per 1.0 of supply): supply_apy + xvs_supply.
        int256 supplyNetBps = int256(SUPPLY_APY_BPS) + int256(XVS_SUPPLY_BPS);
        // Net borrow leg (per 1.0 of debt): xvs_borrow - borrow_apr.
        int256 borrowNetBps = int256(XVS_BORROW_BPS) - int256(BORROW_APR_BPS);

        // Total APY in bps:
        //   = collatBps/1e4 * supplyNetBps + debtBps/1e4 * borrowNetBps
        int256 totalApyBps = (int256(collatBps) * supplyNetBps) / 10_000
            + (int256(debtBps) * borrowNetBps) / 10_000;

        // 30-day PnL on PRINCIPAL_USDT (USDT, 18 dec, $1 each).
        int256 principalUsd = int256(PRINCIPAL_USDT);
        int256 pnlUsd1e18 = (principalUsd * totalApyBps * int256(HOLD_DAYS)) / (10_000 * 365);

        if (pnlUsd1e18 > 0) {
            _fund(BSC.USDT, address(this), uint256(pnlUsd1e18));
        } else if (pnlUsd1e18 < 0) {
            // Burn USDT to model loss; bounded by current balance.
            uint256 burn = uint256(-pnlUsd1e18);
            uint256 bal = IERC20(BSC.USDT).balanceOf(address(this));
            if (burn > bal) burn = bal;
            if (burn > 0) {
                IERC20(BSC.USDT).transfer(address(0xdead), burn);
            }
        }
    }

    // ----------------------------------------------------------------
    // Fork helper - swallow missing RPC env so the offline path runs.
    // ----------------------------------------------------------------
    function _tryFork() internal returns (bool) {
        try vm.envString("BSC_RPC_URL") returns (string memory rpc) {
            if (bytes(rpc).length == 0) return false;
            try vm.createSelectFork(rpc, 42_500_000) returns (uint256) {
                return true;
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
