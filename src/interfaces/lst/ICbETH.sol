// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Coinbase Wrapped Staked ETH. Exchange-rate appreciating.
interface ICbETH is IERC20 {
    function exchangeRate() external view returns (uint256);
}
