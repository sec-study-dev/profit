// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "src/interfaces/common/IERC4626.sol";

/// @notice Sky sUSDS - ERC-4626 over USDS, accrues the Sky Savings Rate.
interface ISUSDS is IERC4626 {
    function ssr() external view returns (uint256); // savings rate (RAY per-second)
    function chi() external view returns (uint192);
    function rho() external view returns (uint64);
    function drip() external returns (uint256);
}
