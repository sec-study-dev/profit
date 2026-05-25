// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Maker DSS PSM (USDC <-> DAI 1:1 with a fee).
interface IDssPsm {
    /// @notice Swap gemAmt of GEM (e.g. USDC with 6 decimals) -> DAI to `usr`.
    function sellGem(address usr, uint256 gemAmt) external;
    /// @notice Swap DAI from caller -> gemAmt of GEM to `usr`.
    function buyGem(address usr, uint256 gemAmt) external;
    function tin() external view returns (uint256);
    function tout() external view returns (uint256);
    function gemJoin() external view returns (address);
    function dai() external view returns (address);
    function vat() external view returns (address);
}
