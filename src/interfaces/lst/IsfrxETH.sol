// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "src/interfaces/common/IERC4626.sol";

/// @notice Frax staked frxETH. ERC-4626 over frxETH as asset.
interface IsfrxETH is IERC4626 {
    /// @notice Frax-specific: rewards-per-second over a window.
    function rewardsCycleEnd() external view returns (uint32);
    function lastSync() external view returns (uint32);
    function rewardsCycleLength() external view returns (uint32);
    function syncRewards() external;
    function pricePerShare() external view returns (uint256);
}
