// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Rocket Pool rETH. Non-rebasing, exchange-rate appreciating.
interface IRETH is IERC20 {
    function getExchangeRate() external view returns (uint256);
    function getEthValue(uint256 rethAmount) external view returns (uint256);
    function getRethValue(uint256 ethAmount) external view returns (uint256);
    function getTotalCollateral() external view returns (uint256);
    function getCollateralRate() external view returns (uint256);
    /// @notice Burn rETH for ETH from the deposit pool (subject to liquidity).
    function burn(uint256 rethAmount) external;
}

/// @notice Rocket deposit pool - mints rETH from ETH deposit.
interface IRocketDepositPool {
    function deposit() external payable;
    function getBalance() external view returns (uint256);
    function getMaximumDepositAmount() external view returns (uint256);
}
