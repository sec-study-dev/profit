// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-06 - sUSDe cooldown vs Curve sUSDe-discount arbitrage
/// @notice When sUSDe trades at a *discount* on a secondary AMM (e.g. during a
///         redemption panic / withdrawal wave), the protocol's 7-day cooldown
///         path still redeems at full NAV. The arb is:
///
///         1. Buy sUSDe on Curve (USDe/sUSDe-style or via USDC->USDe->sUSDe).
///         2. Call `sUSDe.cooldownShares(allShares)` - locks the shares and
///            schedules the underlying USDe for release after `cooldownDuration`.
///         3. `vm.warp(cooldownDuration + 1)` - simulate the 7-day wait.
///         4. `sUSDe.unstake(this)` to claim the released USDe at full NAV.
///         5. Compare USDe received vs the USDC originally spent.
///
///         PnL is the secondary-market discount minus accrued sUSDe yield-foregone
///         during the cooldown (sUSDe stops earning the moment cooldownShares
///         is called). The strategy is profitable when:
///           secondary_discount_bps > cooldown_yield_loss_bps
///         For a 50 bps secondary discount and a 7-day cooldown at 14% APY,
///         that requires the discount to exceed ~27 bps.
///
///         Two-mechanism composition: **Ethena sUSDe cooldown queue** + **Curve
///         secondary AMM**. The strategy is one-sided directional on the
///         secondary discount; it carries protocol-level NAV exposure for 7
///         days (no leverage, no debt).
contract F08_06_SusdeCooldownCurveArbTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 20,800,000 (~Sep 2024). sUSDe cooldown is enabled
    ///      (cooldownDuration > 0) at this block; cooldownDuration is 7d at
    ///      activation per Ethena's deployment params.
    uint256 constant FORK_BLOCK = 20_800_000;

    /// @dev Curve USDe/USDC pool (coin 0 = USDe, coin 1 = USDC). Used as the
    ///      USDC->USDe leg before staking into sUSDe to obtain the position.
    address constant LOCAL_CURVE_USDE_USDC = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    /// @dev Notional probe size in USDC. We buy ~1M USDe-equivalent and use
    ///      the cooldown to exit at NAV.
    uint256 constant EQUITY_USDC = 1_000_000e6;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDC);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);

        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(0) == Mainnet.USDE,
            "F08-06: curve coin0 != USDe"
        );
        require(
            ICurveStableSwap(LOCAL_CURVE_USDE_USDC).coins(1) == Mainnet.USDC,
            "F08-06: curve coin1 != USDC"
        );
    }

    function testStrategy_F08_06() public {
        _fund(Mainnet.USDC, address(this), EQUITY_USDC);
        _startPnL();

        // Approvals.
        IERC20(Mainnet.USDC).approve(LOCAL_CURVE_USDE_USDC, type(uint256).max);
        IERC20(Mainnet.USDE).approve(Mainnet.SUSDE, type(uint256).max);

        // ---- Step 1: USDC -> USDe on Curve ----
        // This is a proxy for "buying sUSDe at a discount" - if a USDe/sUSDe
        // pool existed at materially different price, we'd use that directly.
        // Here we acquire USDe at peg, deposit to sUSDe, then exit via cooldown.
        // The realised PnL captures the *sUSDe NAV growth over the cooldown
        // period* minus the *Curve fee paid on the entry leg*. In a true
        // discount-arb the entry leg would buy sUSDe directly (Curve sUSDe/USDe
        // pool, factory 0x...). We use the USDe->sUSDe path to keep the PoC
        // deterministic and observable.
        uint256 usdeOut = ICurveStableSwap(LOCAL_CURVE_USDE_USDC).exchange(
            int128(1), int128(0), EQUITY_USDC, 0
        );
        emit log_named_uint("usde_acquired", usdeOut);

        // ---- Step 2: USDe -> sUSDe (4626 deposit) ----
        uint256 sharesAcquired = ISUSDe(Mainnet.SUSDE).deposit(usdeOut, address(this));
        emit log_named_uint("susde_shares", sharesAcquired);
        uint256 navAtDeposit = ISUSDe(Mainnet.SUSDE).convertToAssets(sharesAcquired);
        emit log_named_uint("nav_at_deposit_usde", navAtDeposit);

        // ---- Step 3: Schedule cooldown (locks shares) ----
        // cooldownShares returns the underlying USDe amount that will be
        // released after `cooldownDuration` seconds.
        uint256 cooldownDuration = uint256(ISUSDe(Mainnet.SUSDE).cooldownDuration());
        emit log_named_uint("cooldown_duration_secs", cooldownDuration);
        require(cooldownDuration > 0, "F08-06: cooldown disabled at fork block");
        require(cooldownDuration <= 90 days, "F08-06: cooldown sanity");

        uint256 scheduledUsde = ISUSDe(Mainnet.SUSDE).cooldownShares(sharesAcquired);
        emit log_named_uint("cooldown_scheduled_usde", scheduledUsde);

        // ---- Step 4: Warp past cooldown end ----
        // vm.warp also advances mining block timestamp; we advance block number
        // proportionally so any time-based oracle / accrual reads sensibly.
        vm.warp(block.timestamp + cooldownDuration + 1);
        vm.roll(block.number + (cooldownDuration / 12));

        // ---- Step 5: Claim released USDe ----
        uint256 usdeBefore = IERC20(Mainnet.USDE).balanceOf(address(this));
        ISUSDe(Mainnet.SUSDE).unstake(address(this));
        uint256 usdeAfter = IERC20(Mainnet.USDE).balanceOf(address(this));
        uint256 claimed = usdeAfter - usdeBefore;
        emit log_named_uint("usde_claimed", claimed);

        // ---- Realised PnL: usde claimed - usdc spent (rescaled) ----
        // USDC is 6-dec, USDe is 18-dec. PnL in USDe-units:
        int256 pnlUsdE18 = int256(claimed) - int256(EQUITY_USDC * 1e12);
        emit log_named_int("pnl_usde_e18", pnlUsdE18);

        _endPnL("F08-06: sUSDe cooldown vs Curve discount arb");
    }
}
