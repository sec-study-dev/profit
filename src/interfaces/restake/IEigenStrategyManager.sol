// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice EigenLayer StrategyManager - deposit LSTs into per-asset strategies.
interface IEigenStrategyManager {
    function depositIntoStrategy(address strategy, address token, uint256 amount) external returns (uint256 shares);

    function depositIntoStrategyWithSignature(
        address strategy,
        address token,
        uint256 amount,
        address staker,
        uint256 expiry,
        bytes calldata signature
    ) external returns (uint256 shares);

    function stakerStrategyShares(address user, address strategy) external view returns (uint256);
    function stakerStrategyListLength(address staker) external view returns (uint256);
    function getDeposits(address staker)
        external
        view
        returns (address[] memory strategies, uint256[] memory shares);
    function strategyIsWhitelistedForDeposit(address strategy) external view returns (bool);
}

/// @notice EigenLayer per-asset Strategy.
interface IEigenStrategy {
    function deposit(address token, uint256 amount) external returns (uint256);
    function withdraw(address recipient, address token, uint256 amountShares) external;
    function sharesToUnderlying(uint256 amountShares) external returns (uint256);
    function sharesToUnderlyingView(uint256 amountShares) external view returns (uint256);
    function underlyingToShares(uint256 amountUnderlying) external returns (uint256);
    function underlyingToSharesView(uint256 amountUnderlying) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function underlyingToken() external view returns (address);
}
