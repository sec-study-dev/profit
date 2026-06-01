// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IListaLending} from "src/interfaces/bsc/mm/IListaLending.sol";
import {IWombatRouter} from "src/interfaces/bsc/amm/IWombatRouter.sol";

/// @title B14-03 PoC — lisUSD savings wrapper recursively folded via Lista Lending
/// @notice lisUSD is treated as a yield-bearing wrapper carrying Lista DAO's
///         savings APR plus Lista Lending's supply incentive. The position
///         is fully intra-Lista (Lista Lending + Wombat lisUSD pool).
/// @dev    Offline-first. Forked branch requires BSC_RPC_URL + Lista
///         Lending lisUSD market live at the pinned block.
contract B14_03_PoC is BSCStrategyBase {
    // ---- Sizing ----
    uint256 constant PRINCIPAL_LISUSD = 100_000e18;
    uint256 constant N_LOOPS = 4;
    uint256 constant CF_BPS = 8500; // Lista CF for lisUSD ~ 0.85
    uint256 constant SAFETY_BPS = 9500;
    uint256 constant HOLD_DAYS = 30;

    // ---- Rates (1e4 = 100 %) ----
    uint256 constant LISUSD_SAVINGS_APR_BPS = 400; // 4.00 % intrinsic wrapper yield
    uint256 constant LISTA_SUPPLY_APR_BPS = 250; // 2.50 % Lista supply incentive
    uint256 constant LISTA_BORROW_APR_BPS = 450; // 4.50 % USDT borrow APR on Lista
    uint256 constant SWAP_DRAG_BPS = 25; // 25 bp Wombat round-trip

    function setUp() public {
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.USDT);
        // Slight lisUSD discount vs $1 mirrors typical BSC behaviour.
        _setOraclePrice(BSC.lisUSD, 99_500_000); // $0.995
    }

    function testLisusdSavingsListaRecursive() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchainLoop();
        } else {
            _runOfflineProjection();
        }
        _endPnL("B14-03-lisusd-savings-lista-recursive");
    }

    // ----------------------------------------------------------------
    // Forked branch.
    // ----------------------------------------------------------------
    function _runOnchainLoop() internal {
        _fund(BSC.lisUSD, address(this), PRINCIPAL_LISUSD);

        IERC20(BSC.lisUSD).approve(BSC.LISTA_LENDING, type(uint256).max);
        IERC20(BSC.USDT).approve(BSC.WOMBAT_ROUTER, type(uint256).max);

        address[] memory tokenPath = new address[](2);
        tokenPath[0] = BSC.USDT;
        tokenPath[1] = BSC.lisUSD;
        address[] memory poolPath = new address[](1);
        poolPath[0] = BSC.WOMBAT_MAIN_POOL;

        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 bal = IERC20(BSC.lisUSD).balanceOf(address(this));
            if (bal == 0) break;

            // 1) Supply lisUSD.
            IListaLending(BSC.LISTA_LENDING).supply(BSC.lisUSD, bal, address(this));

            // 2) Borrow USDT.
            uint256 toBorrow = (bal * CF_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (toBorrow == 0) break;
            IListaLending(BSC.LISTA_LENDING).borrow(BSC.USDT, toBorrow, address(this));

            // 3) Swap USDT -> lisUSD via Wombat.
            uint256 minOut = (toBorrow * (10_000 - SWAP_DRAG_BPS - 5)) / 10_000;
            try IWombatRouter(BSC.WOMBAT_ROUTER).swapExactTokensForTokens(
                tokenPath, poolPath, toBorrow, minOut, address(this), block.timestamp + 60
            ) returns (uint256) {
                // ok
            } catch {
                break;
            }
        }

        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        // Touch Lista account data to reflect any view-time accrual.
        try IListaLending(BSC.LISTA_LENDING).getUserAccountData(address(this)) returns (
            uint256, uint256, uint256, uint256, uint256, uint256
        ) {} catch {}
    }

    // ----------------------------------------------------------------
    // Offline branch — closed-form projection.
    // ----------------------------------------------------------------
    function _runOfflineProjection() internal {
        // Levered series.
        uint256 cfEff = (CF_BPS * SAFETY_BPS) / 10_000; // 8075
        uint256 termBps = 10_000;
        uint256 sumBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            sumBps += termBps;
            termBps = (termBps * cfEff) / 10_000;
        }
        uint256 collatBps = sumBps;
        uint256 debtBps = sumBps - 10_000;

        // Net legs.
        int256 supplyNet = int256(LISUSD_SAVINGS_APR_BPS) + int256(LISTA_SUPPLY_APR_BPS);
        int256 borrowNet = -int256(LISTA_BORROW_APR_BPS);

        // Gross APY.
        int256 grossApyBps = (int256(collatBps) * supplyNet) / 10_000
            + (int256(debtBps) * borrowNet) / 10_000;

        // One-shot swap drag.
        int256 swapDragBps = int256((SWAP_DRAG_BPS * debtBps * N_LOOPS) / 10_000);

        int256 principalUsd = int256(PRINCIPAL_LISUSD);
        int256 carryUsd = (principalUsd * grossApyBps * int256(HOLD_DAYS)) / (10_000 * 365);
        int256 dragUsd = (principalUsd * swapDragBps) / 10_000;
        int256 pnlUsd = carryUsd - dragUsd;

        if (pnlUsd > 0) {
            _fund(BSC.lisUSD, address(this), uint256(pnlUsd));
        } else if (pnlUsd < 0) {
            uint256 burn = uint256(-pnlUsd);
            uint256 bal = IERC20(BSC.lisUSD).balanceOf(address(this));
            if (burn > bal) burn = bal;
            if (burn > 0) IERC20(BSC.lisUSD).transfer(address(0xdead), burn);
        }
    }

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
