// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StrategyBase} from "test/utils/StrategyBase.t.sol";
import {Mainnet} from "src/constants/Mainnet.sol";
import {Whales} from "test/utils/Whales.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IEigenStrategyManager, IEigenStrategy} from "src/interfaces/restake/IEigenStrategyManager.sol";
import {console2} from "forge-std/console2.sol";

/// @notice EigenLayer StrategyManager pause check - per-index variant (EL V1 uses uint8 key).
interface IPausable {
    function paused(uint8 index) external view returns (bool);
}

/// @notice Scalar pause variant: paused() returns uint256 bitmask.
interface IPausable2 {
    function paused() external view returns (uint256);
}

/// @notice F15-02 - EigenLayer cap-race "first into the window" PoC.
///
/// At a block where a cap window is freshly open, deposit the full equity
/// before crowd-fill. Measure (a) the share of `totalShares()` we capture and
/// (b) the time-density advantage by rolling forward 30 blocks and re-checking.
contract F15_02_EigenCapRaceFirstDepositTest is StrategyBase {
    address constant STETH_STRATEGY = 0x93c4b944D05dfe6df7645A86cd2206016c51564D;

    /// @dev Target block: an early-Apr 2024 cap-open. The PoC handles cap-closed
    ///      cases gracefully and falls back to a known-open block via try/catch.
    uint256 constant FORK_BLOCK = 19_500_021;
    /// @dev Fallback if `FORK_BLOCK` is cap-closed.
    ///      19_650_000 has the StrategyManager globally paused; 19_700_000 is
    ///      confirmed unpaused and whitelisted at that block.
    uint256 constant FALLBACK_BLOCK = 19_700_000;

    uint256 constant EQUITY = 100 ether;

    function setUp() public {
        _fork(FORK_BLOCK);
        _trackToken(Mainnet.STETH);
    }

    function testStrategy_F15_02() public {
        IEigenStrategyManager sm = IEigenStrategyManager(Mainnet.EIGEN_STRATEGY_MANAGER);

        // If FORK_BLOCK has the strategy unwhitelisted OR the StrategyManager globally
        // paused (bitmap index 0), re-fork to the fallback.
        // Note: `strategyIsWhitelistedForDeposit` does NOT reflect the pause state; we
        // must also check `paused(0)` directly. The bitmap `paused()` returns a uint256
        // where bit 0 corresponds to the deposit function.
        bool capOpen = sm.strategyIsWhitelistedForDeposit(STETH_STRATEGY);
        bool globallyPaused;
        try IPausable(address(sm)).paused(uint8(0)) returns (bool p) {
            globallyPaused = p;
        } catch {
            // older interface: try scalar `paused()` returning uint256 bitmask
            try IPausable2(address(sm)).paused() returns (uint256 bm) {
                globallyPaused = (bm & 1) != 0;
            } catch {}
        }
        if (!capOpen || globallyPaused) {
            console2.log("FORK_BLOCK cap closed or paused; falling back to", FALLBACK_BLOCK);
            _fork(FALLBACK_BLOCK);
        }

        address whale = Whales.whaleOf(Mainnet.STETH);
        require(whale != address(0), "no stETH whale");
        vm.prank(whale);
        IERC20(Mainnet.STETH).transfer(address(this), EQUITY);

        _startPnL();

        IEigenStrategy strat = IEigenStrategy(STETH_STRATEGY);

        // ---- Snapshot BEFORE ----
        uint256 sharesBefore = strat.totalShares();
        uint256 blockBefore = block.number;
        console2.log("totalShares BEFORE:", sharesBefore);
        console2.log("block BEFORE:", blockBefore);

        // ---- Race-deposit ----
        IERC20(Mainnet.STETH).approve(Mainnet.EIGEN_STRATEGY_MANAGER, EQUITY);
        uint256 ourShares = 0;
        try sm.depositIntoStrategy(STETH_STRATEGY, Mainnet.STETH, EQUITY) returns (uint256 sh) {
            ourShares = sh;
        } catch Error(string memory reason) {
            console2.log("cap-race deposit reverted:", reason);
        } catch {
            console2.log("cap-race deposit reverted (unknown)");
        }
        console2.log("our shares:", ourShares);

        // ---- Forward-roll: simulate 30 blocks of cap-fill by other depositors ----
        // We can't actually generate other depositors on the fork, but rolling
        // demonstrates that totalShares is monotone non-decreasing and we lock
        // our slice at this block's rate.
        uint256 sharesAfterDeposit = strat.totalShares();
        vm.roll(block.number + 30);
        uint256 sharesAfterRoll = strat.totalShares();

        console2.log("totalShares AFTER our deposit:", sharesAfterDeposit);
        console2.log("totalShares AFTER 30-block roll:", sharesAfterRoll);

        // Our share-of-strategy at deposit-time:
        if (sharesAfterDeposit > 0 && ourShares > 0) {
            uint256 ourBpsOfStrategy = (ourShares * 10_000) / sharesAfterDeposit;
            console2.log("our share of strategy (bps):", ourBpsOfStrategy);
        }

        _endPnL("F15-02: eigen-cap-race-first-deposit");

        require(ourShares > 0, "cap-race deposit failed on both blocks; pin a known-open block");
    }
}
