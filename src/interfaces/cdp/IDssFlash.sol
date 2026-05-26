// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice MakerDAO ERC-3156 DAI flash mint.
interface IDssFlash {
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool);
    function maxFlashLoan(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function max() external view returns (uint256);
    function toll() external view returns (uint256);
}
