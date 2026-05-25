// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "src/interfaces/common/IERC4626.sol";

/// @notice Puffer pufETH is an ERC-4626 vault over stETH.
interface IPufETH is IERC4626 {
    /// @notice Puffer-specific deposit-stETH-and-mint helper. May not be present on all versions.
    function depositStETH(uint256 stETHSharesAmount, address recipient) external returns (uint256);
    /// @notice Puffer-specific deposit-wstETH helper.
    function depositWstETH(uint256 wstETHAmount, address recipient) external returns (uint256);
}
