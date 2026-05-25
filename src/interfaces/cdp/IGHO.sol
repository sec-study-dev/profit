// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Aave GHO token + facilitator. Borrowing GHO is done via the Aave V3 Pool
///         (see IAavePool.borrow with asset = GHO). This interface is for tokens-side
///         queries and the discount strategy.
interface IGHO is IERC20 {
    function getFacilitator(address facilitator) external view returns (uint128 bucketCapacity, uint128 bucketLevel);
    function getFacilitatorBucket(address facilitator) external view returns (uint128, uint128);
    function getFacilitatorsList() external view returns (address[] memory);
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
}
