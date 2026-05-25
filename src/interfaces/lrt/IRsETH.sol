// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Kelp DAO rsETH token + deposit pool entrypoints. Most-used functions:
///   - LRTDepositPool.depositETH(uint256 minRsEthOut, string referralId)
///   - LRTDepositPool.depositAsset(address asset, uint256 amount, uint256 minRsEthOut, string referralId)
///   - getRsETHAmountToMint(address asset, uint256 amount) view returns (uint256)
/// Extend in family F02 / F03 as needed.
interface IRsETH is IERC20 {}

interface IKelpDepositPool {
    function depositETH(uint256 minRSETHAmountExpected, string calldata referralId) external payable;
    function depositAsset(
        address asset,
        uint256 depositAmount,
        uint256 minRSETHAmountExpected,
        string calldata referralId
    ) external;
    function getRsETHAmountToMint(address asset, uint256 amount) external view returns (uint256);
}
