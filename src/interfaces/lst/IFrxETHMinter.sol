// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Frax frxETH minter - submits ETH, optionally auto-stakes to sfrxETH.
interface IFrxETHMinter {
    function submit() external payable;
    function submitAndDeposit(address recipient) external payable returns (uint256 shares);
    function submitAndGive(address recipient) external payable;
}
