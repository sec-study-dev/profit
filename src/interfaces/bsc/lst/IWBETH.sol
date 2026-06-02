// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Binance Wrapped Beacon ETH (WBETH). Non-rebasing.
interface IWBETH is IERC20 {
    /// @notice ETH per 1 WBETH (1e18 scaled).
    function exchangeRate() external view returns (uint256);
    /// @notice Direct ETH -> WBETH deposit (payable).
    function deposit(address referral) external payable;
    // TODO: confirm `deposit` signature on the BSC deployment; mainnet ETH
    //       deployment uses `deposit(address)` returning shares.
}
