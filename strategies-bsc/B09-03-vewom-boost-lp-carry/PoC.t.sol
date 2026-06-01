// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";

/// @title B09-03 veWOM lock + Wombat LP boosted-carry (positional, multi-block)
/// @notice Multi-block PoC modelling:
///         t=0 :
///           - buy `W` WOM tokens at $0.10
///           - lock for 365d -> 3.6 * W veWOM
///           - deposit `L` USDT into Wombat Main Pool, receive LP
///           - stake LP into MasterWombat
///         t=+30d :
///           - claim emissions (modelled: base + boosted)
///           - record PnL: emission USD value - WOM mark-to-market - gas
/// @dev Since the repo has no `IMasterWombat` / `IVeWOM` interfaces yet, the
///      PoC operates entirely in offline-accounting mode, mirroring the
///      mainnet `verify-cycle` PoCs that use `vm.warp` and direct token
///      balance writes to model rewards.
contract B09_03_VeWOM_Boost_LPCarry is BSCStrategyBase {
    /// @dev TODO: pin real BSC blocks for entry and exit. ~3s blocks * 30d ≈ 864_000.
    uint256 constant FORK_BLOCK_START = 45_000_000;
    uint256 constant FORK_BLOCK_END   = 45_864_000;

    /// @dev Position sizes.
    uint256 constant LP_USDT_NOTIONAL = 1_000_000 ether;
    uint256 constant WOM_BUY = 250_000 ether; // 250k WOM at $0.10 = $25k

    /// @dev Lock duration in days (max in current Wombat is ~365d).
    uint256 constant LOCK_DAYS = 365;
    /// @dev Linear ve multiplier: 1 + (lockDays / 365) * 2.6 -> 3.6x at 365d.
    /// @dev Modelled multiplier expressed as parts-per-10000.
    uint256 constant VE_MULT_BPS = 36000; // 3.6x

    /// @dev Hold horizon in seconds.
    uint256 constant HOLD_SECONDS = 30 days;

    /// @dev Modelled annualized rates expressed as bps of LP notional.
    uint256 constant BASE_APR_BPS = 400;   // 4% base WOM emissions APR
    uint256 constant FEE_APR_BPS = 100;    // 1% trading-haircut fee share
    /// @dev Boost multiplier on the emission leg, expressed as bps. Modelled
    ///      as a function of V/L (`veWOM / LP_value`). At V=900k, L=$1M, the
    ///      Wombat boost curve typically prints ~2.2x.
    uint256 constant BOOST_MULT_BPS = 22000; // 2.2x

    /// @dev WOM mark price (USD, 1e8 scaled).
    uint256 constant WOM_PRICE_E8 = 10_000_000; // $0.10

    uint256 public veWomGranted;
    uint256 public lpReceived;
    uint256 public emissionUsdE6;

    bool internal _haveFork;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK_START);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.USDT);
        _trackToken(BSC.WOM);

        // WOM oracle: $0.10
        _setOraclePrice(BSC.WOM, WOM_PRICE_E8);
    }

    function testStrategy_B09_03() public {
        // Both modes share the same positional accounting; the on-fork variant
        // exercises Wombat.deposit / withdraw to confirm those selectors work.
        _fund(BSC.WOM, address(this), WOM_BUY);
        _fund(BSC.USDT, address(this), LP_USDT_NOTIONAL);

        _startPnL();

        // ---- Lock leg (modelled) ----
        veWomGranted = (WOM_BUY * VE_MULT_BPS) / 10000;
        // In production this would call MasterWombat.lockVeWOM(WOM_BUY, 365d).
        // PoC consumes the WOM by sending it to a sink to mimic the lock.
        IERC20(BSC.WOM).transfer(address(0xdead), WOM_BUY);

        // ---- LP leg ----
        if (_haveFork) {
            IERC20(BSC.USDT).approve(BSC.WOMBAT_MAIN_POOL, LP_USDT_NOTIONAL);
            lpReceived = IWombatPool(BSC.WOMBAT_MAIN_POOL).deposit(
                BSC.USDT,
                LP_USDT_NOTIONAL,
                0,
                address(this),
                block.timestamp,
                false
            );
        } else {
            // Offline mode: assume 1:1 LP / asset since Wombat single-side
            // deposits target a `liability` accounting unit.
            lpReceived = LP_USDT_NOTIONAL;
            IERC20(BSC.USDT).transfer(address(0xdead), LP_USDT_NOTIONAL);
        }

        // ---- Advance ~30 days ----
        vm.warp(block.timestamp + HOLD_SECONDS);
        if (_haveFork) {
            vm.roll(FORK_BLOCK_END);
        }

        // ---- Compute emissions ----
        // base + boosted emission rate, applied for 30/365 of the year.
        uint256 effEmissionApr = BASE_APR_BPS * BOOST_MULT_BPS / 10000;
        uint256 emissionLpUsd = LP_USDT_NOTIONAL * effEmissionApr / 10000 * HOLD_SECONDS / 365 days;
        uint256 feeUsd        = LP_USDT_NOTIONAL * FEE_APR_BPS    / 10000 * HOLD_SECONDS / 365 days;
        uint256 totalCarry    = emissionLpUsd + feeUsd;
        emissionUsdE6         = totalCarry / 1e12; // 18-dec USDT -> 1e6 USD

        // ---- Materialize the emission as USDT (PoC convention: emissions are
        //      auto-compounded into the underlying stable for clean PnL).
        _fund(BSC.USDT, address(this), totalCarry);

        // ---- Withdraw LP leg ----
        if (_haveFork) {
            IERC20(IWombatPool(BSC.WOMBAT_MAIN_POOL).addressOfAsset(BSC.USDT))
                .approve(BSC.WOMBAT_MAIN_POOL, lpReceived);
            IWombatPool(BSC.WOMBAT_MAIN_POOL).withdraw(
                BSC.USDT, lpReceived, 0, address(this), block.timestamp
            );
        } else {
            _fund(BSC.USDT, address(this), LP_USDT_NOTIONAL);
        }

        // veWOM stays locked across the snapshot window — booked as a
        // realized cost: the $25k of WOM is consumed (sent to dead) so the
        // PnL accounts for it via the WOM-token balance delta.

        _endPnL("B09-03: veWOM boosted LP carry 30d");
    }
}
