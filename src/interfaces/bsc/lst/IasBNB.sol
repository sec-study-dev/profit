// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Astherus asBNB (restaked BNB share token).
interface IasBNB is IERC20 {
    /// @notice BNB-denominated value per 1 asBNB share (1e18 scaled).
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    /// @notice ERC-4626-like preview helpers (if exposed).
    // TODO: confirm asBNB share/asset conversion API; using ERC-4626 placeholders.
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
}
