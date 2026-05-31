// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Wombat StableSwap pool (dynamic-asset-weight invariant).
interface IWombatPool {
    function swap(
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 minimumToAmount,
        address to,
        uint256 deadline
    ) external returns (uint256 actualToAmount, uint256 haircut);

    function quotePotentialSwap(address fromToken, address toToken, uint256 fromAmount)
        external
        view
        returns (uint256 potentialOutcome, uint256 haircut);

    function deposit(
        address token,
        uint256 amount,
        uint256 minimumLiquidity,
        address to,
        uint256 deadline,
        bool shouldStake
    ) external returns (uint256 liquidity);

    function withdraw(
        address token,
        uint256 liquidity,
        uint256 minimumAmount,
        address to,
        uint256 deadline
    ) external returns (uint256 amount);

    function addressOfAsset(address token) external view returns (address);
}
