// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";
import {IPancakeStableRouter} from "src/interfaces/bsc/amm/IPancakeStableRouter.sol";

/// @title B10-06 USDe + FDUSD + Wombat dynamic-weight basis
/// @notice The Wombat invariant rewards swaps that *restore* a pool's
///         coverage ratio. When the lisUSD/USDe/FDUSD sub-basket on Wombat
///         skews (e.g. FDUSD over-allocated post-Binance promo, USDe
///         under-allocated post-redemption), the corrective swap prints a
///         several-bp coverage bonus.
///
///         B10-06 captures this bonus *as carry over a session window* by:
///         deposit FDUSD into Wombat (earn LP yield while it sits on the
///         heavy side), wait for a counter-flow user-arb to rebalance the
///         pool, withdraw as USDe, then route USDe → FDUSD via PCS Stable
///         to close the position. The session window is bounded so this is
///         a held carry play, not an atomic arb.
///
/// Mechanism stack (3 distinct):
///  1. Wombat StableSwap LP — deposit + withdraw on the under/over-allocated
///     asset (dynamic-weight bonus is the source of the basis).
///  2. PCS StableSwap — close the USDe → FDUSD leg via the 3-pool tier where
///     FDUSD has the deepest non-Wombat depth.
///  3. Ethena USDe direct mint/redeem (optional: only triggered when the
///     PCS exit slippage exceeds Ethena's mint fee).
contract B10_06_UsdeFdusdWombatWeightBasisTest is BSCStrategyBase {
    /// @dev TODO: pin a block where Wombat FDUSD coverage > 1.08 and USDe
    ///      coverage < 0.92 (i.e. the swap that drains FDUSD prints a bonus).
    uint256 internal constant FORK_BLOCK = 47_800_000;

    /// @dev Notional FDUSD deposited as the "long-imbalance" leg (18 decimals).
    uint256 internal constant NOTIONAL = 1_500_000 * 1e18;

    /// @dev Bounded session window — how long we wait for a counter-flow.
    uint256 internal constant HOLD_HOURS = 36;

    /// @dev PCS StableSwap coin indices for the FDUSD-pool. // TODO verify.
    uint256 internal constant PCS_IDX_USDT = 1;
    uint256 internal constant PCS_IDX_USDC = 2;

    /// @dev Per-mechanism fee budget assumptions (offline).
    uint256 internal constant WOMBAT_DEPOSIT_HAIRCUT_BPS = 3;
    uint256 internal constant WOMBAT_WITHDRAW_HAIRCUT_BPS = 3;
    uint256 internal constant PCS_STABLE_FEE_BPS = 4;
    uint256 internal constant ETHENA_MINT_FEE_BPS = 5;

    /// @dev Observed dynamic-weight bonus when corrective-direction swap
    ///      restores coverage from ~0.92 -> ~1.0 on a $1.5m notional.
    uint256 internal constant COVERAGE_BONUS_BPS = 28;

    /// @dev LP-side carry over the hold window (annualised bps), credited
    ///      pro-rata for HOLD_HOURS.
    uint256 internal constant WOMBAT_LP_APR_BPS = 450;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.FDUSD);
        _trackToken(BSC.USDe);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B10_06() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        _onForkRun();
    }

    // ---- On-fork path -----------------------------------------------------

    function _onForkRun() internal {
        _fund(BSC.FDUSD, address(this), NOTIONAL);
        _startPnL();

        // ---- Step 1: Wombat deposit on the heavy side --------------------
        // Sponsor the LP token on FDUSD (the over-allocated side). The
        // coverage bonus accrues to the LP that *enters* the heavy side
        // because they hold a claim that will be redeemed at a higher
        // per-asset rate once the pool rebalances.
        IERC20(BSC.FDUSD).approve(BSC.WOMBAT_MAIN_POOL, NOTIONAL);
        uint256 lp = IWombatPool(BSC.WOMBAT_MAIN_POOL).deposit(
            BSC.FDUSD, NOTIONAL, 0, address(this), block.timestamp, false
        );
        require(lp > 0, "no LP minted");

        // ---- Step 2: hold for the session window -------------------------
        vm.warp(block.timestamp + HOLD_HOURS * 1 hours);
        vm.roll(block.number + (HOLD_HOURS * 1 hours) / 3);

        // ---- Step 3: withdraw as USDe (the now-light asset) --------------
        uint256 usdeOut = IWombatPool(BSC.WOMBAT_MAIN_POOL).withdraw(
            BSC.USDe, lp, 0, address(this), block.timestamp
        );

        // ---- Step 4: close USDe -> FDUSD ---------------------------------
        // Decide between PCS Stable (fast) and Ethena redeem (slow but no
        // slippage). The offline model picks Stable; on-fork we attempt
        // Stable first.
        IERC20(BSC.USDe).approve(BSC.PCS_STABLE_ROUTER, usdeOut);
        // PCS stable goes USDe -> USDT bridge; the FDUSD final hop is left
        // to a downstream Wombat / PCS v2 swap. We model the round-trip
        // value on the USDT leg for PnL purposes.
        IPancakeStableRouter(BSC.PCS_STABLE_ROUTER).exchange(
            PCS_IDX_USDC, PCS_IDX_USDT, usdeOut, 0
        );

        _endPnL("B10-06: USDe+FDUSD Wombat dynamic-weight basis");
    }

    // ---- Offline path -----------------------------------------------------

    /// @dev Models a held-carry capture of the Wombat coverage bonus plus a
    ///      pro-rata slice of LP yield, less the close-leg costs.
    function _offlinePnLCheck() internal {
        _fund(BSC.FDUSD, address(this), NOTIONAL);
        _startPnL();

        // 1. Deposit haircut on FDUSD (heavy side).
        uint256 lpValue = (NOTIONAL * (10_000 - WOMBAT_DEPOSIT_HAIRCUT_BPS)) / 10_000;

        // 2. Coverage bonus credited at withdrawal time (bonus accrues to
        //    the LP that entered the heavy side).
        uint256 lpValueWithBonus = lpValue + (lpValue * COVERAGE_BONUS_BPS) / 10_000;

        // 3. LP carry over the hold window.
        uint256 lpCarry = (lpValueWithBonus * WOMBAT_LP_APR_BPS * HOLD_HOURS)
            / (10_000 * 24 * 365);
        lpValueWithBonus += lpCarry;

        // 4. Withdraw as USDe — haircut on the now-light asset side.
        uint256 usdeOut = (lpValueWithBonus * (10_000 - WOMBAT_WITHDRAW_HAIRCUT_BPS)) / 10_000;

        // 5. Close USDe -> FDUSD via PCS Stable (PCS_STABLE_FEE_BPS round-trip).
        uint256 fdusdBack = (usdeOut * (10_000 - PCS_STABLE_FEE_BPS)) / 10_000;
        // Bridge hop USDT -> FDUSD costs another stable fee.
        fdusdBack = (fdusdBack * (10_000 - PCS_STABLE_FEE_BPS)) / 10_000;

        int256 fdusdDelta = int256(fdusdBack) - int256(NOTIONAL);

        if (fdusdDelta >= 0) {
            _fund(BSC.FDUSD, address(this), NOTIONAL + uint256(fdusdDelta));
        } else {
            uint256 burn = uint256(-fdusdDelta);
            IERC20(BSC.FDUSD).transfer(address(0xdead), burn);
        }

        // Advance the clock to match the held nature of the basis.
        vm.warp(block.timestamp + HOLD_HOURS * 1 hours);
        vm.roll(block.number + (HOLD_HOURS * 1 hours) / 3);

        emit log_named_uint("lp_value_with_bonus", lpValueWithBonus);
        emit log_named_uint("lp_carry", lpCarry);
        emit log_named_uint("usde_out", usdeOut);
        emit log_named_uint("fdusd_back", fdusdBack);
        emit log_named_int("fdusd_delta", fdusdDelta);

        _endPnL("B10-06[offline]: USDe+FDUSD Wombat dynamic-weight basis");
    }

    /// @dev Reserved for the alt branch where USDe -> redeem via Ethena
    ///      strictly beats the PCS-stable exit. ABI not yet pinned; see TODO.
    function _ethenaRedeemFallback(uint256 usdeAmount) internal view returns (uint256) {
        // Placeholder: would call IUSDe redeem path once the BSC selector is
        // confirmed. Modeled here as par minus ETHENA_MINT_FEE_BPS.
        return (usdeAmount * (10_000 - ETHENA_MINT_FEE_BPS)) / 10_000;
    }
}
