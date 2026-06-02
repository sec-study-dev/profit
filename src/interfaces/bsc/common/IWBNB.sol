// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Wrapped BNB. Mirrors WETH9: deposit/withdraw + ERC20.
interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
