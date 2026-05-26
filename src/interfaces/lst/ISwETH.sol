// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Swell swETH. Non-rebasing, exchange-rate-based.
interface ISwETH is IERC20 {
    function deposit() external payable;
    function swETHToETHRate() external view returns (uint256);
    function ethToSwETHRate() external view returns (uint256);
    function getRate() external view returns (uint256);
}
