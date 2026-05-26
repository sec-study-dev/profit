// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Pendle Standardized Yield (SY) token - wraps a yield-bearing asset
///         into a single-token interface.
interface IStandardizedYield is IERC20 {
    function deposit(address receiver, address tokenIn, uint256 amountTokenToDeposit, uint256 minSharesOut)
        external
        payable
        returns (uint256 amountSharesOut);

    function redeem(
        address receiver,
        uint256 amountSharesToRedeem,
        address tokenOut,
        uint256 minTokenOut,
        bool burnFromInternalBalance
    ) external returns (uint256 amountTokenOut);

    function exchangeRate() external view returns (uint256);
    function accruedRewards(address user) external view returns (uint256[] memory);
    function getRewardTokens() external view returns (address[] memory);
    function claimRewards(address user) external returns (uint256[] memory);

    function yieldToken() external view returns (address);
    function getTokensIn() external view returns (address[] memory);
    function getTokensOut() external view returns (address[] memory);

    function previewDeposit(address tokenIn, uint256 amountTokenToDeposit) external view returns (uint256);
    function previewRedeem(address tokenOut, uint256 amountSharesToRedeem) external view returns (uint256);

    enum AssetType { TOKEN, LIQUIDITY }
    function assetInfo() external view returns (AssetType, address, uint8);
}
