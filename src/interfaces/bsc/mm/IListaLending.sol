// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Lista Lending market (isolated slisBNB / lisUSD collateral pools).
/// @dev    Surface follows the standard supply/borrow shape; confirm exact
///         selectors against the deployed Lista Lending contract.
interface IListaLending {
    function supply(address asset, uint256 amount, address onBehalfOf) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, address onBehalfOf) external;
    function repay(address asset, uint256 amount, address onBehalfOf) external returns (uint256);

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    // TODO: replace with canonical Lista Lending ABI once published.
}
