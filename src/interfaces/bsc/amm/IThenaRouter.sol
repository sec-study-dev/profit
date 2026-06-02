// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Thena Router (Solidly/Velodrome fork). Routes specify stable vs.
///         volatile pair flag.
interface IThenaRouter {
    struct Route {
        address from;
        address to;
        bool stable;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, Route[] calldata routes)
        external
        view
        returns (uint256[] memory amounts);

    function pairFor(address tokenA, address tokenB, bool stable) external view returns (address pair);
}
