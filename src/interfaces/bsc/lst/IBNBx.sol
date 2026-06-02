// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Stader BNBx (non-rebasing LST).
interface IBNBx is IERC20 {
    /// @notice BNB amount per 1 BNBx share (1e18 scaled).
    function getExchangeRate() external view returns (uint256);
    // TODO: confirm exact getter; some Stader deployments expose
    //       `convertBnbXToBnb(uint256)` instead.
}
