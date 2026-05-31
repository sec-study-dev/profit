// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice PancakeSwap V3 Factory.
interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}
