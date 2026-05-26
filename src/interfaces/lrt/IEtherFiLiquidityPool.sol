// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice EtherFi liquidity pool - accepts ETH, mints eETH 1:1 (rebasing).
interface IEtherFiLiquidityPool {
    function deposit() external payable returns (uint256);
    function deposit(address referral) external payable returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256);
    function amountForShare(uint256 share) external view returns (uint256);
    function sharesForAmount(uint256 amount) external view returns (uint256);
    function getTotalPooledEther() external view returns (uint256);
}
