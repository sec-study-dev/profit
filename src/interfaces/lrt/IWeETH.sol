// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice EtherFi weETH (wrapped eETH).
interface IWeETH is IERC20 {
    function wrap(uint256 eETHAmount) external returns (uint256);
    function unwrap(uint256 weETHAmount) external returns (uint256);
    function getRate() external view returns (uint256);
    function getEETHByWeETH(uint256 weETHAmount) external view returns (uint256);
    function getWeETHByeETH(uint256 eETHAmount) external view returns (uint256);
    function eETH() external view returns (address);
}
