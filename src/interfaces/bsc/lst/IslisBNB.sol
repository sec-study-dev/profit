// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Lista DAO slisBNB (non-rebasing LST). Exchange rate is monotonic.
interface IslisBNB is IERC20 {
    /// @notice BNB amount per 1 slisBNB share. 1e18 scaled.
    function convertToBNB(uint256 shares) external view returns (uint256);
    /// @notice slisBNB share amount per 1 BNB. 1e18 scaled.
    function convertToShares(uint256 bnb) external view returns (uint256);
    // TODO: confirm exact getter names against canonical slisBNB ABI.
}
