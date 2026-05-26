// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Mountain Protocol USDM. Rebasing token; allow-listed transfers.
/// @dev    Most-used functions: balanceOf, rewardMultiplier, convertToShares,
///         convertToTokens. Mint/burn is allow-listed and not used by PoCs.
interface IUSDM is IERC20 {
    function rewardMultiplier() external view returns (uint256);
    function convertToShares(uint256 amount) external view returns (uint256);
    function convertToTokens(uint256 shares) external view returns (uint256);
    function sharesOf(address account) external view returns (uint256);
}
