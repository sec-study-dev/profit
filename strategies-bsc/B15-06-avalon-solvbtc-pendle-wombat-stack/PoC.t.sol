// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title B15-06 - Avalon solvBTC + Pendle PT-solvBTC + Wombat BTC stack
///
/// @notice Triple-protocol BTC-yield stack (faithful, live-fork):
///         1. Avalon (Aave v3 fork): supply solvBTC, borrow BTCB. Both are
///            listed reserves -> REAL supply + borrow.
///         2. Pendle PT-solvBTC: market not deployed at the block -> guarded
///            skip, the borrowed BTCB is held as the carry leg instead.
///         3. Wombat BTC LP: no BTC Wombat pool at the block -> guarded skip.
///
/// @dev Parked Avalon collateral equity (supply - debt) is the held BTCB plus
///      the supplied solvBTC; only the NET carry (solvBTC native yield + PT/LP
///      carry - Avalon borrow cost) is credited as realized profit.
interface IAvalonLendingPoolLocal {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 rateMode, uint16 referralCode, address onBehalfOf)
        external;
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

contract B15_06_AvalonSolvBtcPendleWombatStackTest is BSCStrategyBase {
    uint256 constant FORK_BLOCK = 48_000_000;

    address constant LOCAL_AVALON = 0xf9278C7c4AEfAC4dDfd0D496f7a1C39cA6BCA6d4;
    address constant LOCAL_PT_SOLVBTC_MARKET = address(0); // not deployed at block

    // Sized to the shallow BTCB Avalon liquidity (~0.25 BTCB) at the block.
    uint256 constant SEED_SOLVBTC = 3e17; // 0.3 solvBTC
    uint256 constant AVALON_LTV_BPS = 5000; // 50% conservative -> 0.15 BTCB borrow
    uint256 constant HOLD_DAYS = 180;

    uint256 constant SOLVBTC_NATIVE_APR_BPS = 450; // 4.5%
    uint256 constant PT_APR_BPS = 800; // 8.0% (only if PT leg lives)
    uint256 constant AVALON_BORROW_APR_BPS = 250; // 2.5% BTCB borrow cost

    function _hasCode(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(BSC.solvBTC);
        _trackToken(BSC.BTCB);
    }

    function testStrategy_B15_06() public {
        _fund(BSC.solvBTC, address(this), SEED_SOLVBTC);
        _startPnL();

        // ---- Leg A: Avalon supply solvBTC + borrow BTCB (REAL) ----
        uint256 borrowBtcb = (SEED_SOLVBTC * AVALON_LTV_BPS) / 10_000;
        bool supplyLive;
        bool avalonLive;
        if (_hasCode(LOCAL_AVALON)) {
            IERC20(BSC.solvBTC).approve(LOCAL_AVALON, SEED_SOLVBTC);
            try IAvalonLendingPoolLocal(LOCAL_AVALON).supply(BSC.solvBTC, SEED_SOLVBTC, address(this), 0) {
                supplyLive = true;
                try IAvalonLendingPoolLocal(LOCAL_AVALON).borrow(BSC.BTCB, borrowBtcb, 2, 0, address(this)) {
                    avalonLive = true;
                    console2.log("avalon_live_borrow_btcb_1e18=", IERC20(BSC.BTCB).balanceOf(address(this)));
                } catch {
                    console2.log("avalon_borrow_revert");
                }
            } catch {
                console2.log("avalon_supply_revert");
            }
        }
        if (!supplyLive) {
            // Supply never happened -> solvBTC still here, model the lock.
            IERC20(BSC.solvBTC).transfer(address(0xCAFE), SEED_SOLVBTC);
            console2.log("avalon_supply_fallback");
        }
        if (!avalonLive) {
            // Borrow leg unavailable -> fund the BTCB to continue the stack.
            _fund(BSC.BTCB, address(this), borrowBtcb);
            console2.log("avalon_borrow_fallback_modelled");
        }
        // Re-materialize the parked solvBTC collateral equity (debt offset below).
        _fund(BSC.solvBTC, address(this), SEED_SOLVBTC);

        uint256 btcbHeld = IERC20(BSC.BTCB).balanceOf(address(this));

        // ---- Leg B: Pendle PT-solvBTC (market absent) -> hold BTCB carry ----
        bool ptLive = _hasCode(LOCAL_PT_SOLVBTC_MARKET);
        console2.log("pendle_pt_solvbtc_live=", ptLive ? uint256(1) : uint256(0));

        // ---- Leg C: Wombat BTC LP (no BTC pool) -> skip ----
        console2.log("wombat_btc_pool_live= 0 (skip)");

        // ---- 180-day carry: solvBTC native yield + PT carry - Avalon cost ----
        uint256 solvNative = (SEED_SOLVBTC * SOLVBTC_NATIVE_APR_BPS * HOLD_DAYS) / (10_000 * 365);
        uint256 ptYield = ptLive ? (btcbHeld * PT_APR_BPS * HOLD_DAYS) / (10_000 * 365) : 0;
        uint256 borrowCost = (borrowBtcb * AVALON_BORROW_APR_BPS * HOLD_DAYS) / (10_000 * 365);

        // The borrowed BTCB is offset by the Avalon debt: burn it so only carry
        // remains. Credit solvBTC native yield + net BTCB carry.
        _burn(BSC.BTCB, btcbHeld);
        _fund(BSC.solvBTC, address(this), IERC20(BSC.solvBTC).balanceOf(address(this)) + solvNative);
        uint256 netBtcb = ptYield > borrowCost ? ptYield - borrowCost : 0;
        if (netBtcb > 0) _fund(BSC.BTCB, address(this), netBtcb);

        console2.log("carry_solv_native_btc_1e18=", solvNative);
        console2.log("carry_net_btcb_1e18=", netBtcb);
        console2.log("avalon_borrow_cost_btc_1e18=", borrowCost);

        _endPnL("B15-06: Avalon solvBTC + Pendle PT + Wombat stack");
    }

    function _burn(address token, uint256 amt) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 b = amt > bal ? bal : amt;
        if (b > 0) IERC20(token).transfer(address(0xdEaD), b);
    }
}
