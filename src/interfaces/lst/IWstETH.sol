// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

interface IWstETH is IERC20 {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);
    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
    function tokensPerStEth() external view returns (uint256);
    function stETH() external view returns (address);
}
