// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Liquity v1 / v2 TroveManager (subset). v2 expects troveId/owner;
///         v1 uses borrower address as the implicit trove ID.
/// @dev Extend with v1-specific or v2-specific fields per family F06.
interface ITroveManager {
    function getTroveStatus(uint256 troveId) external view returns (uint256);
    function getTroveDebt(uint256 troveId) external view returns (uint256);
    function getTroveColl(uint256 troveId) external view returns (uint256);
    function getCurrentICR(uint256 troveId, uint256 price) external view returns (uint256);

    function liquidate(uint256 troveId) external;
    function batchLiquidateTroves(uint256[] calldata troveArray) external;

    function redeemCollateral(
        uint256 amount,
        uint256 maxIterations,
        uint256 maxFeePercentage
    ) external;
}
