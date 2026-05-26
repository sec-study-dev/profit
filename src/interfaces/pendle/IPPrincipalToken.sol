// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Pendle Principal Token (PT). 1 PT redeems for 1 unit of accounting asset at expiry.
interface IPPrincipalToken is IERC20 {
    function SY() external view returns (address);
    function YT() external view returns (address);
    function expiry() external view returns (uint256);
    function isExpired() external view returns (bool);
    function factory() external view returns (address);
    function burnByYT(address user, uint256 amount) external;
    function mintByYT(address user, uint256 amount) external;
}
