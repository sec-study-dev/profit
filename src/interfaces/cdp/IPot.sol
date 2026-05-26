// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Maker Pot (DSR savings rate accumulator).
interface IPot {
    function dsr() external view returns (uint256); // per-second rate, RAY
    function chi() external view returns (uint256); // accumulated rate, RAY
    function rho() external view returns (uint256); // last drip timestamp
    function pie(address usr) external view returns (uint256);
    function Pie() external view returns (uint256);
    function drip() external returns (uint256);
    function join(uint256 wad) external;
    function exit(uint256 wad) external;
}
