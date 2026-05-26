// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Generic Balancer pool (BPT). Returns getPoolId, getVault, and
///         common rate helpers (boosted/composable pools have these).
interface IBalancerPool {
    function getPoolId() external view returns (bytes32);
    function getVault() external view returns (address);
    function totalSupply() external view returns (uint256);
    function getRate() external view returns (uint256);
    function getSwapFeePercentage() external view returns (uint256);
    function getScalingFactors() external view returns (uint256[] memory);
}
