// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Ankr ankrBNB (non-rebasing wrapped LST).
interface IankrBNB is IERC20 {
    /// @notice BNB amount per 1 ankrBNB share (1e18 scaled).
    function ratio() external view returns (uint256);
    /// @notice Convenience wrapper used by Ankr UIs.
    function sharesToBonds(uint256 shares) external view returns (uint256);
    /// @notice Convenience wrapper used by Ankr UIs.
    function bondsToShares(uint256 bonds) external view returns (uint256);
}
