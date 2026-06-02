// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IBNBx} from "src/interfaces/bsc/lst/IBNBx.sol";
import {IListaLending} from "src/interfaces/bsc/mm/IListaLending.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {console2} from "forge-std/console2.sol";

interface IStaderStakeManager {
    function deposit() external payable;
    function getExchangeRate() external view returns (uint256);
}

/// @title B01-07 BNBx → Lista Lending → borrow WBNB → Wombat WBNB/BNBx recycle (3-mech)
///
/// @notice Three-mechanism stack:
///         1. **Stader BNBx**   — mint LST from BNB at internal rate.
///         2. **Lista Lending** — supply BNBx as collateral, borrow WBNB.
///         3. **Wombat WBNB / BNBx StableSwap-style pool** — instead of
///            re-staking the borrowed WBNB into Stader (slow async unwind,
///            same-rate roundtrip), swap WBNB → BNBx in the Wombat
///            dynamic-asset pool. When Wombat's BNBx-side ratio is short
///            (i.e. pool is depleted of BNBx), the swap delivers BNBx at a
///            **better effective rate than Stader's mint**, producing a
///            per-loop boost on top of the stake-rate carry.
///
/// @dev    Discriminator vs. B01-02:
///         - Routes borrowing through Lista Lending (not Venus), to
///           diversify borrow IRM.
///         - Routes the LST re-mint through Wombat instead of Stader, so
///           the loop can extract Wombat asset-weight skew as bonus yield.
///         - Falls back to Stader mint if Wombat path is unprofitable.
contract B01_07_BNBxListaWombatRecycleLoopTest is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 41_500_000;

    /// @dev Stader BNBx StakeManager (see B01-02).
    address internal constant LOCAL_STADER_STAKE_MANAGER = 0x7276241a669489E4BBB76f63d2A43Bfe63080F2F;
    /// @dev Stader BNBx ERC20 (mirrors BSC.BNBx, inlined to dodge BSC.sol
    ///      checksum issues per family constraint).
    address internal constant LOCAL_BNBX = 0x1BDD3CF7F79cFB8edbb955F20aD99211044f6AE4;

    /// @dev Lista Lending pool address.
    address internal constant LOCAL_LISTA_LENDING = 0xAa0F8C41E3DC22a8C4d4Da6Da1A1caF048D7e4B5;

    /// @dev Wombat BNBx / WBNB dynamic pool (separate from the main stable
    ///      pool — has its own contract for BNB-LST pairs). Placeholder;
    ///      verify against Wombat's BSC pool registry.
    address internal constant LOCAL_WOMBAT_BNBX_POOL = 0x10010078a54396F62c96dF8532dc2B4847d47ED3;

    uint256 internal constant PRINCIPAL_BNB = 100 ether;
    uint256 internal constant ITERATIONS = 4;
    uint256 internal constant SAFETY_BPS = 9_500;
    uint256 internal constant HOLD_DAYS = 30;

    /// @dev Minimum bonus (bps over Stader's mint rate) required to take
    ///      the Wombat path. If Wombat quotes worse than Stader by less
    ///      than ~5 bps after haircut, fall back to direct Stader mint.
    uint256 internal constant WOMBAT_MIN_EDGE_BPS = 5;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.WBNB);
        _trackToken(LOCAL_BNBX);
    }

    function testStrategy_B01_07() public {
        vm.deal(address(this), PRINCIPAL_BNB);
        _startPnL();

        IStaderStakeManager stader = IStaderStakeManager(LOCAL_STADER_STAKE_MANAGER);
        IBNBx bnbx = IBNBx(LOCAL_BNBX);
        IListaLending lending = IListaLending(LOCAL_LISTA_LENDING);
        IWBNB wbnb = IWBNB(BSC.WBNB);
        IWombatPool wombat = IWombatPool(LOCAL_WOMBAT_BNBX_POOL);

        bnbx.approve(LOCAL_LISTA_LENDING, type(uint256).max);
        bnbx.approve(LOCAL_WOMBAT_BNBX_POOL, type(uint256).max);
        wbnb.approve(LOCAL_LISTA_LENDING, type(uint256).max);
        wbnb.approve(LOCAL_WOMBAT_BNBX_POOL, type(uint256).max);

        // ---- Initial: BNB → BNBx via Stader (cold-start: no Wombat liquidity
        //               check needed; full principal goes through canonical mint).
        stader.deposit{value: PRINCIPAL_BNB}();
        lending.supply(LOCAL_BNBX, bnbx.balanceOf(address(this)), address(this));

        for (uint256 i = 0; i < ITERATIONS; i++) {
            // 1. Borrow WBNB at SAFETY_BPS of available.
            (, , uint256 availBase, , , ) = lending.getUserAccountData(address(this));
            uint256 borrowBnb = (availBase * 1e10) / 600;
            borrowBnb = (borrowBnb * SAFETY_BPS) / 10_000;
            if (borrowBnb == 0) break;

            lending.borrow(BSC.WBNB, borrowBnb, address(this));
            uint256 wbnbBal = IERC20(BSC.WBNB).balanceOf(address(this));
            if (wbnbBal == 0) break;

            // 2. Compare paths:
            //    A. Stader mint: WBNB → BNB → Stader → BNBx at internal rate.
            //    B. Wombat swap: WBNB → BNBx at pool's marginal rate.
            uint256 staderBnbx = (wbnbBal * 1e18) / stader.getExchangeRate();

            uint256 wombatBnbx = 0;
            try wombat.quotePotentialSwap(BSC.WBNB, LOCAL_BNBX, wbnbBal)
                returns (uint256 outBnbx, uint256)
            {
                wombatBnbx = outBnbx;
            } catch {
                wombatBnbx = 0;
            }

            // 3. Take Wombat if it pays at least WOMBAT_MIN_EDGE_BPS more BNBx
            //    than Stader; else fall back to Stader mint. Both paths leave
            //    the freshly-minted/swapped BNBx in `address(this)`; we then
            //    supply the contract's full BNBx balance into Lista.
            uint256 minEdge = (staderBnbx * (10_000 + WOMBAT_MIN_EDGE_BPS)) / 10_000;
            if (wombatBnbx >= minEdge) {
                (uint256 actualOut, ) = wombat.swap(
                    BSC.WBNB,
                    LOCAL_BNBX,
                    wbnbBal,
                    (wombatBnbx * 9_990) / 10_000, // 10 bps slippage tolerance
                    address(this),
                    block.timestamp + 1
                );
                console2.log("path=wombat,bnbx_out_1e18=", actualOut);
            } else {
                wbnb.withdraw(wbnbBal);
                stader.deposit{value: address(this).balance}();
                console2.log("path=stader,bnbx_balance_1e18=", bnbx.balanceOf(address(this)));
            }

            uint256 freshBnbx = bnbx.balanceOf(address(this));
            if (freshBnbx == 0) break;

            // 4. Re-supply to Lista Lending.
            lending.supply(LOCAL_BNBX, freshBnbx, address(this));
        }

        // Hold 30 days.
        vm.warp(block.timestamp + HOLD_DAYS * 1 days);
        vm.roll(block.number + (HOLD_DAYS * 1 days) / 3);

        // Re-mark BNBx by Stader rate (Wombat skew should converge over time).
        uint256 bnbPerBnbx = stader.getExchangeRate();
        _setOraclePrice(LOCAL_BNBX, (600e8 * bnbPerBnbx) / 1e18);

        (, uint256 debtBase, , , , uint256 hf) = lending.getUserAccountData(address(this));
        emit log_named_uint("lista_debt_base_1e8", debtBase);
        emit log_named_uint("lista_hf_1e18", hf);
        emit log_named_uint("bnbx_rate_1e18", bnbPerBnbx);

        _endPnL("B01-07: BNBx Lista + Wombat recycle");
    }
}
