// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice lisUSD stability controller (PSM-like flows + peg defense).
/// @dev    Placeholder ABI; downstream agents (B03) should refine once Lista
///         publishes the canonical contract surface.
interface ILisUSDController {
    /// @notice Swap stable -> lisUSD at peg (PSM-style).
    function swapInto(address stable, uint256 amount) external returns (uint256 lisOut);
    /// @notice Swap lisUSD -> stable at peg.
    function swapOutOf(address stable, uint256 amount) external returns (uint256 stableOut);

    /// @notice Current stability fee (per second, 1e27 scaled).
    function stabilityFee() external view returns (uint256);
    /// @notice Current debt ceiling for the lisUSD line.
    function debtCeiling() external view returns (uint256);
    // TODO: replace with real lisUSD controller / Vat selectors.
}
