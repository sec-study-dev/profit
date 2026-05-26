// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Lido stETH. Rebasing token: balanceOf grows over time.
interface IStETH is IERC20 {
    function submit(address referral) external payable returns (uint256 shares);
    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function getTotalPooledEther() external view returns (uint256);
    function transferShares(address recipient, uint256 sharesAmount) external returns (uint256);
}
