// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Lista DAO CDP Interaction - open vaults, deposit collateral, mint
///         lisUSD. MakerDAO-style architecture.
interface IListaInteraction {
    /// @notice Deposit `amount` of `token` collateral into the user's CDP.
    function deposit(address participant, address token, uint256 amount) external;
    /// @notice Withdraw `amount` of collateral.
    function withdraw(address participant, address token, uint256 amount) external;
    /// @notice Mint `amount` of lisUSD against deposited collateral.
    function borrow(address token, uint256 amount) external;
    /// @notice Repay `amount` of lisUSD debt.
    function payback(address token, uint256 amount) external;

    /// @notice Returns the current debt for `participant` in `token` market.
    function borrowed(address token, address participant) external view returns (uint256);
    /// @notice Returns the deposited collateral for `participant` in `token` market.
    function locked(address token, address participant) external view returns (uint256);
    // TODO: confirm exact selectors against the deployed Interaction proxy.
}
