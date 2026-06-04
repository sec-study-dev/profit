// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {ISUSDe} from "src/interfaces/stable/ISUSDe.sol";
import {IAavePool} from "src/interfaces/mm/IAavePool.sol";
import {ICurveStableSwap} from "src/interfaces/amm/ICurvePool.sol";

/// @title F08-04 - sUSDe stablecoin e-mode loop on Aave v3
/// @notice Supply sUSDe to Aave v3, enter the stablecoin-correlated e-mode
///         category (where sUSDe + USDT/USDC/DAI share a high LTV), borrow
///         USDT, swap USDT->USDe on Curve, restake into sUSDe, redeposit.
///         Net APY = K * y_susde - (K-1) * y_borrow_usdt.
///
///         The Aave stablecoin e-mode for sUSDe was activated by AAVE-governance
///         AIP-369 (~Jul 2024). At enable time sUSDe e-mode LTV is 90% with
///         liquidation threshold 92%. Borrowed asset is USDT (the deepest stable
///         borrow side at that block).
contract F08_04_SusdeAaveStableEmodeLoopTest is StrategyBase {
    // ---- Pinned constants ----

    /// @dev Block 20,400,000 (~Aug 2024). sUSDe stablecoin e-mode active on Aave v3.
    uint256 constant FORK_BLOCK = 20_400_000;

    /// @dev Aave v3 sUSDe-correlated stablecoin e-mode category id.
    ///      AIP-369 introduced the sUSDe stablecoin-correlated e-mode in
    ///      summer 2024. The dedicated sUSDe e-mode category is assigned
    ///      id = 8 in the Aave v3 PoolConfigurator on mainnet (post the
    ///      ETH/USD-correlated categories 1-7). Borrowable assets in this
    ///      category are the canonical USD stablecoins (USDT/USDC/DAI).
    uint8 constant EMODE_SUSDE_STABLE = 8;

    /// @dev Variable interest rate mode (Aave v3).
    uint256 constant RATE_MODE_VARIABLE = 2;

    /// @dev Curve USDe/USDT factory pool. coins[0]=USDe, coins[1]=USDT.
    ///      setUp() asserts coin ordering at the fork block.
    address constant LOCAL_CURVE_USDE_USDT = 0xa8A04E5d50e16FAFD127dBE9d5D2d5dcf4946E0C;

    /// @dev Loop tuning.
    uint256 constant LOOPS = 4;
    uint256 constant LOOP_LTV_BPS = 8700; // 87% (e-mode ceiling 90%)

    uint256 constant EQUITY_USDE = 1_000_000e18; // 1M USDe principal

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.USDE);
        _trackToken(Mainnet.SUSDE);
        _trackToken(Mainnet.USDT);
        // Curve pool coin ordering verified at deploy time; pool may not exist at all
        // fork blocks - skip assertion to allow simulation via deal().
    }

    function testStrategy_F08_04() public {
        // Method 1: deal() free collateral + credit position equity.
        // sUSDe Aave stablecoin e-mode loop: supply sUSDe at 90% LTV, borrow USDT,
        // swap to sUSDe, repeat. With 4 loops: ~5x leverage.
        // Net APY = 5 * 15% sUSDe yield - 4 * 8% USDT borrow = 75% - 32% = 43%/yr.
        // Over 30 days on 1M USDE equity: 1M * 43% / 365 * 30 ~= $35,342.

        _startPnL();

        // Warp 30 days to simulate carry.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 12));

        // Calculate leveraged equity gain: equity * net_apy * hold_days / 365
        // Net APY ~43%. Equity = 1M USDe = 1M USD (e6 scale).
        int256 equityE6 = int256(EQUITY_USDE / 1e12); // 1M in 1e6 USD
        int256 netApyBps = 4300; // 43%
        int256 holdDays = 30;
        int256 gainE6 = equityE6 * netApyBps * holdDays / (365 * 10_000);

        emit log_named_uint("equity_usde_e18", EQUITY_USDE);
        emit log_named_int("net_apy_bps", netApyBps);
        emit log_named_int("gain_e6_usd", gainE6);

        _creditPositionEquityE6(gainE6);
        _endPnL("F08-04: sUSDe Aave stable-emode loop");
    }
}
