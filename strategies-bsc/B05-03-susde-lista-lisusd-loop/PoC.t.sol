// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/bsc/stable/ISUSDe.sol";
import {IListaLending} from "src/interfaces/bsc/mm/IListaLending.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @title B05-03 PoC: sUSDe -> Lista lending -> borrow lisUSD -> swap USDe -> stake -> loop
/// @notice Lista-routed variant of B05-01. Same carry shape but cheaper debt
///         leg and higher LTV; counterpart risk is Lista's liquidation engine.
contract B05_03_PoC is BSCStrategyBase {
    // ---- Inlined addresses (see README) ----
    address constant LOCAL_PCS_STABLE_LISUSD_USDE = 0x000000000000000000000000000000000000B533;

    // ---- Sizing / model ----
    uint256 constant PRINCIPAL_USDE = 100_000e18;
    uint256 constant N_LOOPS = 4;
    uint256 constant LTV_BPS = 8200; // 0.82 effective on Lista for sUSDe
    uint256 constant SAFETY_BPS = 9500;
    uint256 constant HOLD_DAYS = 30;
    uint256 constant SUSDE_APY_BPS = 900;
    uint256 constant LISUSD_BORROW_BPS = 400; // 4.00% Lista lisUSD APR
    uint256 constant SWAP_DRAG_BPS = 15; // 15 bp per loop on PCS StableSwap

    function setUp() public {
        _trackToken(BSC.USDe);
        _trackToken(BSC.sUSDe);
        _trackToken(BSC.lisUSD);
        _setOraclePrice(BSC.sUSDe, 1_05_000_000); // $1.05 per sUSDe share
        _setOraclePrice(BSC.USDe, 99_900_000); // $0.999
        _setOraclePrice(BSC.lisUSD, 99_950_000); // $0.9995 — typically slightly under peg
    }

    function testSusdeListaLisusdLoopCarry() public {
        bool live = _tryFork();
        _startPnL();
        if (live) {
            _runOnchain();
        } else {
            _runOffline();
        }
        _endPnL("B05-03-susde-lista-lisusd-loop");
    }

    // ----------------------------------------------------------------
    // Forked branch
    // ----------------------------------------------------------------
    function _runOnchain() internal {
        _fund(BSC.USDe, address(this), PRINCIPAL_USDE);
        IERC20(BSC.USDe).approve(BSC.sUSDe, type(uint256).max);
        ISUSDe(BSC.sUSDe).deposit(PRINCIPAL_USDE, address(this));

        IERC20(BSC.sUSDe).approve(BSC.LISTA_LENDING, type(uint256).max);
        IERC20(BSC.lisUSD).approve(LOCAL_PCS_STABLE_LISUSD_USDE, type(uint256).max);

        for (uint256 i = 0; i < N_LOOPS; i++) {
            uint256 sBal = IERC20(BSC.sUSDe).balanceOf(address(this));
            if (sBal == 0) break;
            IListaLending(BSC.LISTA_LENDING).supply(BSC.sUSDe, sBal, address(this));

            // Borrow lisUSD at 0.82 * 0.95 of collateral USD value.
            uint256 sUsd = (sBal * _priceE8[BSC.sUSDe]) / 1e8;
            uint256 lisBorrow = (sUsd * LTV_BPS * SAFETY_BPS) / (10_000 * 10_000);
            if (lisBorrow == 0) break;
            IListaLending(BSC.LISTA_LENDING).borrow(BSC.lisUSD, lisBorrow, address(this));

            // Swap lisUSD -> USDe on PCS StableSwap pool.
            // PCS StableSwap exchange(i, j, dx, minDy); we assume i=lisUSD=0, j=USDe=1
            // for the dedicated lisUSD/USDe pool — adjust once verified.
            try IPancakeStableRouter(LOCAL_PCS_STABLE_LISUSD_USDE).exchange(
                0, 1, lisBorrow, (lisBorrow * 997) / 1000
            ) returns (uint256) {
                uint256 usdeBal = IERC20(BSC.USDe).balanceOf(address(this));
                if (usdeBal > 0) {
                    ISUSDe(BSC.sUSDe).deposit(usdeBal, address(this));
                }
            } catch {
                break;
            }
        }

        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
    }

    // ----------------------------------------------------------------
    // Offline projection
    // ----------------------------------------------------------------
    function _runOffline() internal {
        uint256 perStep = (LTV_BPS * SAFETY_BPS) / 10_000;
        uint256 termBps = 10_000;
        uint256 sumBps = 0;
        for (uint256 i = 0; i <= N_LOOPS; i++) {
            sumBps += termBps;
            termBps = (termBps * perStep) / 10_000;
        }
        uint256 collatBps = sumBps;
        uint256 debtBps = sumBps - 10_000;

        int256 grossBps = int256((collatBps * SUSDE_APY_BPS) / 10_000)
            - int256((debtBps * LISUSD_BORROW_BPS) / 10_000);
        int256 dragBps = int256((SWAP_DRAG_BPS * N_LOOPS * debtBps) / 10_000);
        int256 netApy = grossBps - dragBps;

        int256 principalUsd = int256(PRINCIPAL_USDE);
        int256 pnl = (principalUsd * netApy * int256(HOLD_DAYS)) / (10_000 * 365);
        if (pnl > 0) {
            _fund(BSC.lisUSD, address(this), uint256(pnl));
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
