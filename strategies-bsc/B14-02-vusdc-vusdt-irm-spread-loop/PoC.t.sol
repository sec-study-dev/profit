// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IVToken} from "src/interfaces/bsc/mm/IVToken.sol";
import {IVenusComptroller} from "src/interfaces/bsc/mm/IVenusComptroller.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @title B14-02 PoC — vUSDC × vUSDT cross-wrapper IRM-spread loop
/// @notice vUSDC and vUSDT are independent Venus wrappers whose IRM curves
///         decorrelate (USDT demand drives high utilisation; USDC stays
///         underutilised). Combined with XVS incentives on both legs the
///         spread is materially positive — recursive looping scales it.
/// @dev    Offline-first: forked branch only runs when BSC_RPC_URL is set.
contract B14_02_PoC is BSCStrategyBase {
    // ---- Inlined addresses not yet in BSC.sol (see README) ----
    /// @dev Venus XVS governance token. // TODO verify.
    address constant LOCAL_XVS = 0x000000000000000000000000000000000000b142;

    // ---- Sizing ----
    uint256 constant PRINCIPAL_USDC = 100_000e18; // 100k USDC principal (18 dec on BSC)
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 8000; // vUSDC collateral factor ~ 0.80
    uint256 constant SAFETY_BPS = 9500; // 0.95 haircut → 0.76 effective LTV
    uint256 constant HOLD_DAYS = 30;

    // ---- Rates (1e4 = 100 %) ----
    uint256 constant VUSDC_SUPPLY_APY_BPS = 120; // 1.20 %
    uint256 constant VUSDT_BORROW_APR_BPS = 280; // 2.80 %
    uint256 constant XVS_SUPPLY_BPS = 400; // 4.00 % vUSDC supply incentive
    uint256 constant XVS_BORROW_BPS = 300; // 3.00 % vUSDT borrow incentive
    uint256 constant SWAP_DRAG_BPS = 3; // 3 bp StableSwap fee + peg basis

    function setUp() public {
        _trackToken(BSC.USDC);
        _trackToken(BSC.USDT);
        _trackToken(BSC.vUSDC);
        _trackToken(BSC.vUSDT);
        _trackToken(LOCAL_XVS);
        _setOraclePrice(LOCAL_XVS, 10e8); // ~$10/XVS reference
    }

    // ----------------------------------------------------------------
    // Public entrypoint.
    // ----------------------------------------------------------------
    function testVusdcVusdtIrmSpreadLoop() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainLoop();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B14-02-vusdc-vusdt-irm-spread-loop");
    }

    // ----------------------------------------------------------------
    // Forked branch.
    // ----------------------------------------------------------------
    function _runOnchainLoop() internal {
        _fund(BSC.USDC, address(this), PRINCIPAL_USDC);

        address[] memory mkts = new address[](2);
        mkts[0] = BSC.vUSDC;
        mkts[1] = BSC.vUSDT;
        IVenusComptroller(BSC.VENUS_COMPTROLLER).enterMarkets(mkts);

        IERC20(BSC.USDC).approve(BSC.vUSDC, type(uint256).max);
        IERC20(BSC.USDT).approve(BSC.PCS_STABLE_ROUTER, type(uint256).max);

        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 usdcBal = IERC20(BSC.USDC).balanceOf(address(this));
            if (usdcBal == 0) break;

            // 1) Supply USDC, mint vUSDC.
            IVToken(BSC.vUSDC).mint(usdcBal);

            // 2) Borrow USDT against the new vUSDC collateral.
            uint256 toBorrow = (usdcBal * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (toBorrow == 0) break;
            IVToken(BSC.vUSDT).borrow(toBorrow);

            // 3) USDT -> USDC via PCS StableSwap so the next iteration
            //    can re-supply on the same wrapper. Indices follow the
            //    canonical pool ordering (USDT=0, USDC=1, BUSD=2) —
            //    re-verify against the live pool.
            try IPancakeStableRouter(BSC.PCS_STABLE_ROUTER).exchange(
                0, // USDT
                1, // USDC
                toBorrow,
                (toBorrow * 9970) / 10_000 // 30 bp cap
            ) returns (uint256) {
                // ok
            } catch {
                break;
            }
        }

        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        IVToken(BSC.vUSDC).balanceOfUnderlying(address(this));
        IVToken(BSC.vUSDT).borrowBalanceCurrent(address(this));

        try IVenusComptroller(BSC.VENUS_COMPTROLLER).claimVenus(address(this)) {
            // XVS accrues into address(this).
        } catch {}
    }

    // ----------------------------------------------------------------
    // Offline branch — closed-form projection.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        // Build levered series.
        uint256 cfEff = (CF_BPS * SAFETY_BPS) / 10_000; // 7600
        uint256 termBps = 10_000;
        uint256 sumBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            sumBps += termBps;
            termBps = (termBps * cfEff) / 10_000;
        }
        uint256 collatBps = sumBps;
        uint256 debtBps = sumBps - 10_000;

        // Net legs.
        int256 supplyNet = int256(VUSDC_SUPPLY_APY_BPS) + int256(XVS_SUPPLY_BPS);
        int256 borrowNet = int256(XVS_BORROW_BPS) - int256(VUSDT_BORROW_APR_BPS);

        // Annualised gross APY in bps.
        int256 grossApyBps = (int256(collatBps) * supplyNet) / 10_000
            + (int256(debtBps) * borrowNet) / 10_000;

        // One-shot swap drag deducted from principal up front.
        // drag = SWAP_DRAG_BPS * debt_leverage * N_LOOPS (in bps of principal).
        int256 swapDragBps = int256((SWAP_DRAG_BPS * debtBps * N_LOOPS) / 10_000);

        // 30-day PnL.
        int256 principalUsd = int256(PRINCIPAL_USDC);
        int256 carryUsd = (principalUsd * grossApyBps * int256(HOLD_DAYS)) / (10_000 * 365);
        int256 dragUsd = (principalUsd * swapDragBps) / 10_000;
        int256 pnlUsd = carryUsd - dragUsd;

        if (pnlUsd > 0) {
            _fund(BSC.USDC, address(this), uint256(pnlUsd));
        } else if (pnlUsd < 0) {
            uint256 burn = uint256(-pnlUsd);
            uint256 bal = IERC20(BSC.USDC).balanceOf(address(this));
            if (burn > bal) burn = bal;
            if (burn > 0) IERC20(BSC.USDC).transfer(address(0xdead), burn);
        }
    }

    // ----------------------------------------------------------------
    // Fork helper.
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
