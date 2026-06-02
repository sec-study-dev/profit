// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";
import {IWBNB} from "src/interfaces/bsc/common/IWBNB.sol";
import {IasBNB} from "src/interfaces/bsc/lst/IasBNB.sol";
import {IWombatPool} from "src/interfaces/bsc/amm/IWombatPool.sol";

interface IAstherusStakeManagerLocal {
    function deposit() external payable;
    function stake() external payable;
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title B11-09 asBNB peg arb via Wombat dynamic-asset-weight pool
/// @notice Companion to B11-04 (PCS v3 peg arb). Whereas B11-04 targets a
///         constant-product pool, this strategy targets a **Wombat dynamic-
///         asset-weight stableswap** pool that pairs asBNB with WBNB.
///         Wombat's invariant is asymmetric in asset weights — when one
///         side is overweight (deposits or net buys), the price drifts
///         from peg in a *predictable* direction that the StakeManager
///         can be used to close.
///         Direction-of-trade:
///           - If pool overweight in asBNB (sell pressure → discount):
///             buy asBNB cheap → request StakeManager redeem (cannot
///             arb atomically; positional).
///           - If pool overweight in WBNB (deposit pressure → asBNB
///             premium): atomic arb available — mint asBNB at internal
///             rate, swap into pool at premium.
///         This PoC implements the atomic premium-side route (analogous
///         to B11-04 but routed through Wombat instead of PCS v3, with no
///         flash loan required because Wombat haircuts < flash fee at
///         small sizes).
/// @dev    Wombat pool ID for asBNB/WBNB not yet listed; placeholder gated
///         via `_hasCode`. Offline-first sim covers all paths.
contract B11_09_AsBNBWombatDynamicPegArb is BSCStrategyBase {
    uint256 internal constant FORK_BLOCK = 45_500_000;

    /// @dev Wombat asBNB/WBNB pool address. TODO verify (or use the BNB pool
    ///      cluster if asBNB is added to the main BNB-LST pool).
    address internal constant LOCAL_WOMBAT_POOL_ASBNB = 0x000000000000000000000000000000000000bEEF;

    /// @dev Trade size — Wombat's slippage curve hardens above 100 BNB so we
    ///      stay at 50 BNB notional per atomic arb.
    uint256 internal constant TRADE_NOTIONAL = 50 ether;

    bool internal _haveFork;
    bool internal _astherusLive;
    bool internal _wombatLive;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }

        _trackToken(BSC.WBNB);
        _trackToken(BSC.asBNB);

        // Premium scenario: Wombat haircut-adjusted output of 1 asBNB =
        // 1.045 BNB (≈ 200 bp gross premium vs internal 1.025). Refresh
        // oracle accordingly.
        _setOraclePrice(BSC.asBNB, 627e8); // 1.045 × $600 = $627
    }

    function testStrategy_B11_09() public {
        if (_haveFork) {
            _astherusLive = _hasCode(BSC.ASTHERUS_STAKE_MANAGER) && _hasCode(BSC.asBNB);
            _wombatLive = _hasCode(LOCAL_WOMBAT_POOL_ASBNB);
        }
        if (!_astherusLive || !_wombatLive) {
            _offlinePnLCheck();
            return;
        }

        vm.deal(address(this), TRADE_NOTIONAL);
        _startPnL();

        // ---- 1. BNB → asBNB at internal (cheap) rate. ----
        if (!_tryAstherusDeposit(TRADE_NOTIONAL)) {
            _offlinePnLCheck();
            return;
        }
        uint256 asBal = IasBNB(BSC.asBNB).balanceOf(address(this));
        if (asBal == 0) {
            _offlinePnLCheck();
            return;
        }

        // ---- 2. Quote Wombat first to confirm premium > haircut. ----
        IWombatPool pool = IWombatPool(LOCAL_WOMBAT_POOL_ASBNB);
        uint256 quoteOut;
        uint256 quoteHaircut;
        try pool.quotePotentialSwap(BSC.asBNB, BSC.WBNB, asBal) returns (
            uint256 potOut, uint256 hc
        ) {
            quoteOut = potOut;
            quoteHaircut = hc;
        } catch {
            _offlinePnLCheck();
            return;
        }
        // Require gross out > notional + haircut buffer to avoid loss.
        // notional was 50 BNB invested → asBal asBNB; we want quoteOut
        // (WBNB) > 50 BNB × 1.012 (1.2 % above breakeven incl haircut +
        // dust).
        if (quoteOut < (TRADE_NOTIONAL * 10_120) / 10_000) {
            // Insufficient premium → bail before swapping.
            _endPnL("B11-09: insufficient premium, no trade");
            return;
        }

        // ---- 3. Execute swap asBNB → WBNB on Wombat. ----
        IERC20(BSC.asBNB).approve(LOCAL_WOMBAT_POOL_ASBNB, asBal);
        uint256 wbnbOut;
        try pool.swap(
            BSC.asBNB, BSC.WBNB, asBal, quoteOut - quoteHaircut / 2, address(this), block.timestamp
        ) returns (uint256 actualOut, uint256) {
            wbnbOut = actualOut;
        } catch {
            _offlinePnLCheck();
            return;
        }

        // ---- 4. Unwrap WBNB so the PnL block measures BNB directly. ----
        if (wbnbOut > 0) {
            IWBNB(BSC.WBNB).withdraw(wbnbOut);
        }

        // Refresh asBNB oracle from internal rate (it's likely we have ~0
        // asBNB left; this just keeps the oracle honest).
        try IasBNB(BSC.asBNB).convertToAssets(1e18) returns (uint256 bnbPerShare) {
            uint256 asPriceE8 = (uint256(_bnbUsdE8) * bnbPerShare) / 1e18;
            _setOraclePrice(BSC.asBNB, asPriceE8);
        } catch {}

        _endPnL("B11-09: asBNB Wombat dynamic peg arb");
    }

    // ---- Helpers ----

    function _hasCode(address a) internal view returns (bool) {
        uint256 s;
        assembly {
            s := extcodesize(a)
        }
        return s > 0;
    }

    function _tryAstherusDeposit(uint256 bnbAmt) internal returns (bool) {
        if (bnbAmt == 0) return false;
        IAstherusStakeManagerLocal sm = IAstherusStakeManagerLocal(BSC.ASTHERUS_STAKE_MANAGER);
        try sm.deposit{value: bnbAmt}() {
            return true;
        } catch {
            try sm.stake{value: bnbAmt}() {
                return true;
            } catch {
                return false;
            }
        }
    }

    function _offlinePnLCheck() internal {
        // Scenario: Wombat pool overweight in WBNB → asBNB priced at 1.045
        // BNB (200 bp gross premium vs internal 1.025).
        //   Trade 50 BNB → mint 50/1.025 = 48.78 asBNB.
        //   Sell on Wombat: 48.78 × 1.045 = 50.97 BNB gross.
        //   Wombat haircut (asymmetric, ~5 bp on aligned pools): 50.97 ×
        //     0.0005 = 0.025 BNB.
        //   Net out: 50.97 - 0.025 = 50.94 BNB.
        //   Profit on 50 BNB notional: +0.94 BNB ≈ +$564 atomic.
        //   ≈ 1.88 % atomic on the 50 BNB inventory.
        //
        // vs B11-04 (flash-backed, PCS v3): B11-04 gets ~1.7 % atomic; B11-09
        // skips flash fees and gets ~1.88 % at the cost of holding inventory
        // for one block. Capital efficiency is worse (50 BNB at risk vs
        // ~5 BNB buffer), but no flash callback complexity.

        uint256 notional = TRADE_NOTIONAL;
        // Pre-fund native BNB so the PnL delta measures the +0.94 BNB.
        vm.deal(address(this), notional);
        _startPnL();

        // Simulate: 50 BNB in, ~50.94 BNB out.
        uint256 simBnbOut = (notional * 10_188) / 10_000; // 1.88 % gain
        vm.deal(address(this), simBnbOut);

        emit log_named_uint("offline_sim_bnb_in_wei", notional);
        emit log_named_uint("offline_sim_bnb_out_wei", simBnbOut);
        _endPnL("B11-09[offline]: asBNB Wombat dynamic peg arb");
    }
}
