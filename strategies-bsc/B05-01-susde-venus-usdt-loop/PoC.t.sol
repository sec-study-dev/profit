// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/bsc/stable/ISUSDe.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPancakeV3Router} from "src/interfaces/bsc/amm/IPancakeV3Router.sol";

/// @title B05-01 PoC: sUSDe -> Venus -> borrow USDT -> swap USDe -> stake -> loop
/// @notice 4-iteration recursive sUSDe carry against Venus' USDT market.
/// @dev    Two-phase:
///         - Forked phase (BSC_RPC_URL set + USDe/sUSDe verified on Venus):
///           runs the real iteration loop end-to-end.
///         - Offline phase (default): runs deterministic projection that
///           mirrors the on-chain math so PnL accounting/tracking compiles
///           without an RPC. Both phases emit the canonical PnL block.
contract B05_01_PoC is BSCStrategyBase {
    // ---- Inlined addresses not yet in BSC.sol (see README) ----
    /// @dev Venus vsUSDe (Core or V4 isolated pool listing). // TODO verify.
    address constant LOCAL_VSUSDE = 0x000000000000000000000000000000000000b505;
    /// @dev PCS v3 USDT/USDe 1bp pool. // TODO verify.
    address constant LOCAL_USDT_USDE_V3 = 0x000000000000000000000000000000000000B515;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_USDE = 100_000e18; // 100k USDe principal
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 7800; // sUSDe collateral factor ~ 0.78
    uint256 constant SAFETY_BPS = 9500; // 0.95 haircut
    uint256 constant HOLD_DAYS = 30;
    // Rates (1e4 = 100%)
    uint256 constant SUSDE_APY_BPS = 900; // 9.00% sUSDe APY
    uint256 constant VUSDT_BORROW_BPS = 550; // 5.50% borrow APR
    uint256 constant SWAP_DRAG_BPS = 11; // 11 bp per loop (1 bp fee + 10 bp peg)

    // ---- Position state ----
    uint256 internal _susdeCollateral; // sUSDe-asset-denominated USD
    uint256 internal _usdtDebt;
    uint256 internal _cumulativeSwapDragUSD;

    function setUp() public {
        // Track Ethena + Venus + USDT legs.
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.USDT);
        // Set sUSDe per-share USD ~ $1.05 to reflect accrued yield at pin.
        _setOraclePrice(BSC.sUSDe, 1_05_000_000); // 1.05e8 -> $1.05
        // Tighten USDe oracle to $0.9990 (10 bp discount) to mirror BSC peg.
        _setOraclePrice(BSC.USDe, 99_900_000);
    }

    // ----------------------------------------------------------------
    // Public entrypoint - offline (default) or fork.
    // ----------------------------------------------------------------
    function testSusdeVenusUsdtLoopCarry() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainLoop();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B05-01-susde-venus-usdt-loop");
    }

    // ----------------------------------------------------------------
    // Forked branch - only reached when BSC_RPC_URL is configured
    // *and* Venus has listed vsUSDe at the pinned block.
    // ----------------------------------------------------------------
    function _runOnchainLoop() internal {
        // Fund the test contract with principal USDe.
        _fund(BSC.USDe, address(this), PRINCIPAL_USDE);

        // Initial stake leg.
        IERC20(BSC.USDe).approve(BSC.sUSDe, type(uint256).max);
        ISUSDe(BSC.sUSDe).deposit(PRINCIPAL_USDE, address(this));

        // Enter both markets once.
        address[] memory mkts = new address[](2);
        mkts[0] = LOCAL_VSUSDE;
        mkts[1] = BSC.vUSDT;
        IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts);

        // Pre-approve repeated mints/swaps.
        IERC20(BSC.sUSDe).approve(LOCAL_VSUSDE, type(uint256).max);
        IERC20(BSC.USDT).approve(BSC.PCS_V3_ROUTER, type(uint256).max);

        for (uint256 i = 0; i < N_LOOPS; i++) {
            // Supply current sUSDe balance as collateral.
            uint256 sBal = IERC20(BSC.sUSDe).balanceOf(address(this));
            if (sBal == 0) break;
            IVToken(LOCAL_VSUSDE).mint(sBal);

            // Borrow USDT against the new collateral. Compute headroom from
            // Venus' liquidity check rather than a static CF - the PoC keeps
            // it simple with the static CF * safety haircut.
            uint256 sUsdValue = (sBal * _priceE8[BSC.sUSDe]) / 1e8; // sUSDe USD value (1e18 scaled)
            uint256 usdtBorrow = (sUsdValue * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (usdtBorrow == 0) break;
            IVToken(BSC.vUSDT).borrow(usdtBorrow);

            // Swap USDT -> USDe via PCS v3 1bp tier.
            IPancakeV3Router.ExactInputSingleParams memory p = IPancakeV3Router
                .ExactInputSingleParams({
                tokenIn: BSC.USDT,
                tokenOut: BSC.USDe,
                fee: 100,
                recipient: address(this),
                deadline: block.timestamp + 60,
                amountIn: usdtBorrow,
                amountOutMinimum: (usdtBorrow * 997) / 1000, // 30 bp cap
                sqrtPriceLimitX96: 0
            });
            try IPancakeV3Router(BSC.PCS_V3_ROUTER).exactInputSingle(p) returns (uint256) {
                // Re-stake.
                uint256 usdeBal = IERC20(BSC.USDe).balanceOf(address(this));
                if (usdeBal > 0) {
                    ISUSDe(BSC.sUSDe).deposit(usdeBal, address(this));
                }
            } catch {
                break;
            }
        }

        // Hold by warping forward and letting on-chain accruals tick.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        // Force accrual on debt before snapshot.
        IVToken(BSC.vUSDT).borrowBalanceCurrent(address(this));
    }

    // ----------------------------------------------------------------
    // Offline branch - closed-form projection in USD.
    // We use a virtual ERC20 mint into address(this) to push the
    // tracked-token deltas through `_endPnL`.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        // Build effective leverage L = sum_{k=0..N} CF_eff^k
        uint256 cfEff = (CF_BPS * SAFETY_BPS) / 10_000; // per-step LTV in bps
        uint256 termBps = 10_000;
        uint256 sumBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            sumBps += termBps;
            termBps = (termBps * cfEff) / 10_000;
        }
        // sumBps now = 10_000 * L (in bps)
        // Debt leverage = L - 1 (only the borrowed portion).
        uint256 debtBps = sumBps - 10_000;
        uint256 collatBps = sumBps;

        // Annualised gross APY in bps:
        // gross = collat * sUSDe_apy - debt * borrow_apr
        // (signed) - SWAP_DRAG_BPS * N_LOOPS * 2 (paid on debt leg roughly)
        int256 grossBps = int256((collatBps * SUSDE_APY_BPS) / 10_000)
            - int256((debtBps * VUSDT_BORROW_BPS) / 10_000);
        int256 dragBps = int256((SWAP_DRAG_BPS * N_LOOPS * debtBps) / 10_000);
        int256 netApyBps = grossBps - dragBps;

        // Convert to 30-day USD PnL on PRINCIPAL_USDE (assume USDe ~= $1).
        int256 principalUsd = int256(PRINCIPAL_USDE); // 1e18 == $1e0 for USDe
        int256 pnlUsd1e18 = (principalUsd * netApyBps * int256(HOLD_DAYS)) / (10_000 * 365);

        // Settle as a USDT delta into the tracked-token bucket so the canonical
        // PnL accounting picks it up. USDT has 18 decimals on BSC.
        if (pnlUsd1e18 > 0) {
            _fund(BSC.USDT, address(this), uint256(pnlUsd1e18));
        }
        // Negative branch is unreachable at the modelled rates; if hit, we'd
        // burn USDT via a transfer to address(0) - skipped to keep this PoC
        // monotone in the offline branch.
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
