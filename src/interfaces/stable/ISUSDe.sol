// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "src/interfaces/common/IERC4626.sol";

/// @notice Ethena sUSDe - ERC-4626 staked USDe with cooldown unstake.
interface ISUSDe is IERC4626 {
    function cooldownDuration() external view returns (uint24);
    function cooldownShares(uint256 shares) external returns (uint256 assets);
    function cooldownAssets(uint256 assets) external returns (uint256 shares);
    function unstake(address receiver) external;
    function cooldowns(address user) external view returns (uint104 cooldownEnd, uint152 underlyingAmount);
}
