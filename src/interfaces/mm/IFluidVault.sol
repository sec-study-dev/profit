// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fluid (Instadapp) per-vault interface (T1 normal vault).
/// @dev    Most-used: operate(nftId, newCol, newDebt, repayApproveAmount, to).
///         A positive newCol/newDebt means add, negative means remove/repay.
///         Extend in family F11 as needed.
interface IFluidVault {
    function operate(
        uint256 nftId_,
        int256 newCol_,
        int256 newDebt_,
        address to_
    ) external payable returns (uint256, int256, int256);

    function liquidate(
        uint256 debtAmt_,
        uint256 colPerUnitDebt_,
        address to_,
        bool absorb_
    ) external payable returns (uint256, uint256);

    function vaultId() external view returns (uint256);
    function getVaultVariables() external view returns (uint256);
    function constantsView() external view returns (address);
}

interface IFluidVaultFactory {
    function deployVault(address vaultDeploymentLogic, bytes calldata vaultDeploymentData)
        external
        returns (address);
    function getVaultAddress(uint256 vaultId) external view returns (address);
    function totalVaults() external view returns (uint256);
}
