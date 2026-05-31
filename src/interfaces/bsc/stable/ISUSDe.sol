// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Ethena sUSDe (ERC-4626 staked USDe) on BSC.
interface ISUSDe is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
    function cooldownDuration() external view returns (uint24);
    function cooldownShares(uint256 shares) external returns (uint256);
    function cooldownAssets(uint256 assets) external returns (uint256);
    function unstake(address receiver) external;
}
