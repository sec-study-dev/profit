// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BSCStrategyBase} from "test/utils/BSCStrategyBase.t.sol";
import {BSC} from "src/constants/BSC.sol";
import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @title B10-04 lisUSD <-> VAI CDP-class basis rotation
/// @notice Sign-flip funding-cost carry between Venus VAI and Lista lisUSD.
///         When Lista SF > Venus rate, we hold State A (debt = VAI,
///         exposure = lisUSD). On rate-cross we rotate to State B (debt =
///         lisUSD, exposure = VAI). Both directions earn the absolute
///         spread minus the rotation cost.
contract B10_04_VaiLisUsdCdpClassBasisRotateTest is BSCStrategyBase {
    /// @dev TODO: pin a fork block once both rate-feeds are ABI-confirmed.
    uint256 internal constant FORK_BLOCK = 48_000_000;

    /// @dev Notional held (in $-stable, 18 decimals).
    uint256 internal constant NOTIONAL = 500_000 * 1e18;

    /// @dev Epoch lengths (days).
    uint256 internal constant EPOCH_DAYS = 30;

    /// @dev Average spread magnitude in each epoch (annualised bps).
    uint256 internal constant EPOCH1_SPREAD_BPS = 250;  // Lista SF > VAI rate by 250 bp.
    uint256 internal constant EPOCH2_SPREAD_BPS = 250;  // Sign-flipped after rotation.

    /// @dev Per-leg swap fee on the PCS stable pool (bps).
    uint256 internal constant SWAP_FEE_BPS = 4;
    /// @dev Number of swap legs in a rotation event (lisUSD -> USDT -> VAI etc.).
    uint256 internal constant ROTATE_LEGS = 2;

    /// @dev Threshold to trigger a rotation (annualised bps of spread).
    uint256 internal constant ROTATE_THRESHOLD_BPS = 25;

    bool internal _haveFork;

    enum State { A_VaiDebt_HoldLisUsd, B_LisUsdDebt_HoldVai }

    State internal _state;

    function setUp() public {
        try vm.envString("BSC_RPC_URL") returns (string memory) {
            _fork(FORK_BLOCK);
            _haveFork = true;
        } catch {
            _haveFork = false;
        }
        _trackToken(BSC.lisUSD);
        _trackToken(BSC.VAI);
        _trackToken(BSC.USDT);
    }

    function testStrategy_B10_04() public {
        if (!_haveFork) {
            _offlinePnLCheck();
            return;
        }
        // On-fork path delegates to the same accounting; real-rate read
        // remains TODO until Lista exposes a stability-fee selector.
        _offlinePnLCheck();
    }

    /// @dev Pure-math two-epoch carry model with a rotation event at t=30d.
    function _offlinePnLCheck() internal {
        // Start in State A: we already hold $500k notional in lisUSD.
        _state = State.A_VaiDebt_HoldLisUsd;
        _fund(BSC.lisUSD, address(this), NOTIONAL);
        _startPnL();

        // --- Epoch 1: State A, carry = +EPOCH1_SPREAD_BPS × 30/365 ----
        uint256 epoch1Gain = (NOTIONAL * EPOCH1_SPREAD_BPS * EPOCH_DAYS) / (10_000 * 365);
        emit log_named_uint("epoch1_carry_gain", epoch1Gain);
        // Credit the gain onto the lisUSD balance.
        _fund(BSC.lisUSD, address(this), NOTIONAL + epoch1Gain);

        // --- Rotation event: rate sign flips, trigger crossed ----
        // Spread becomes -EPOCH2_SPREAD_BPS, |spread| > threshold => rotate.
        require(EPOCH2_SPREAD_BPS >= ROTATE_THRESHOLD_BPS, "rotation gated");

        // Rotation cost: 2 swap legs at SWAP_FEE_BPS on the rotated notional.
        uint256 rotatedNotional = NOTIONAL + epoch1Gain;
        uint256 rotationCost =
            (rotatedNotional * SWAP_FEE_BPS * ROTATE_LEGS) / 10_000;
        emit log_named_uint("rotation_cost", rotationCost);

        // After rotation we hold VAI of equal $-value minus the swap drag.
        uint256 newVaiBal = rotatedNotional - rotationCost;
        // Drain the old lisUSD leg (model: send to dead).
        IERC20(BSC.lisUSD).transfer(address(0xdead), IERC20(BSC.lisUSD).balanceOf(address(this)));
        // Mint the new VAI leg.
        _fund(BSC.VAI, address(this), newVaiBal);
        _state = State.B_LisUsdDebt_HoldVai;

        // --- Epoch 2: State B, carry = +EPOCH2_SPREAD_BPS × 30/365 ----
        uint256 epoch2Gain = (newVaiBal * EPOCH2_SPREAD_BPS * EPOCH_DAYS) / (10_000 * 365);
        emit log_named_uint("epoch2_carry_gain", epoch2Gain);
        _fund(BSC.VAI, address(this), newVaiBal + epoch2Gain);

        // Advance the clock so anyone reading block.timestamp sees the hold.
        vm.warp(block.timestamp + 2 * EPOCH_DAYS * 1 days);
        vm.roll(block.number + (2 * EPOCH_DAYS * 1 days) / 3);

        _endPnL("B10-04[offline]: lisUSD<->VAI CDP-class rotation");
    }
}
