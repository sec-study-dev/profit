// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Thena pair (Solidly fork). Supports both stable (x^3*y + y^3*x = k)
///         and volatile (x*y = k) invariants.
interface IThenaPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function stable() external view returns (bool);
    function getReserves() external view returns (uint256 r0, uint256 r1, uint256 blockTimestampLast);
    function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}
