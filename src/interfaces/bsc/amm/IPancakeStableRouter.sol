// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice PancakeSwap StableSwap Router (Curve StableSwap fork).
/// @dev    // TODO verify selectors against the canonical PCS StableSwap
///         InfoRouter / SwapRouter implementation.
interface IPancakeStableRouter {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external returns (uint256 dy);
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function add_liquidity(uint256[3] calldata amounts, uint256 minMintAmount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 tokenAmount, uint256 i, uint256 minAmount)
        external
        returns (uint256);
}
