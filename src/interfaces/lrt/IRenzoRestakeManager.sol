// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Renzo restake manager - converts ETH/LST into ezETH.
interface IRenzoRestakeManager {
    function depositETH() external payable;
    function deposit(address collateralToken, uint256 amount) external;
    function calculateTVLs() external view returns (uint256[][] memory, uint256[] memory, uint256);
}
