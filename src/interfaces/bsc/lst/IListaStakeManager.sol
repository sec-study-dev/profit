// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Lista DAO StakeManager - BNB <-> slisBNB conversion source of truth.
/// @dev    The StakeManager is the official redeem path: convertBnbToSnBnb +
///         requestWithdraw, and the canonical exchange-rate oracle.
interface IListaStakeManager {
    /// @notice Deposit BNB, receive slisBNB. payable.
    function deposit() external payable;
    /// @notice Initiate a delayed BNB withdrawal by burning `amount` slisBNB.
    function requestWithdraw(uint256 amount) external;
    /// @notice Claim a previously-requested withdrawal (after unbond period).
    function claimWithdraw(uint256 idx) external;

    /// @notice BNB amount per 1 slisBNB share, 1e18 scaled.
    function convertSnBnbToBnb(uint256 amount) external view returns (uint256);
    /// @notice slisBNB share amount per 1 BNB, 1e18 scaled.
    function convertBnbToSnBnb(uint256 amount) external view returns (uint256);
    // TODO: confirm exact public signatures on the deployed StakeManager.
}
