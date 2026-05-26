// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "src/interfaces/common/IERC4626.sol";

/// @notice Euler V2 EVault - ERC-4626 vault with borrow side.
interface IEVault is IERC4626 {
    function borrow(uint256 amount, address receiver) external returns (uint256);
    function repay(uint256 amount, address receiver) external returns (uint256);
    function repayWithShares(uint256 amount, address receiver) external returns (uint256, uint256);
    function pullDebt(uint256 amount, address from) external;

    function totalBorrows() external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
    function debtOfExact(address account) external view returns (uint256);
    function accumulatedFees() external view returns (uint256);
    function interestAccumulator() external view returns (uint256);
    function interestRate() external view returns (uint256);

    function liquidate(address violator, address collateral, uint256 repayAssets, uint256 minYieldBalance)
        external;
    function checkLiquidation(address liquidator, address violator, address collateral)
        external
        view
        returns (uint256 maxRepay, uint256 maxYield);

    function unitOfAccount() external view returns (address);
    function oracle() external view returns (address);
    function EVC() external view returns (address);
    function LTVList() external view returns (address[] memory);
    function LTVBorrow(address collateral) external view returns (uint16);
    function LTVLiquidation(address collateral) external view returns (uint16);
}
