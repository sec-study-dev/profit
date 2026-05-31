// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Venus flash loan (V4). // TODO verify: Venus V4 added flash loans;
///         confirm selector / callback shape against the canonical
///         FlashLoanReceiver interface published by Venus.
interface IVenusFlashLoan {
    function flashLoan(address receiver, address asset, uint256 amount, bytes calldata params) external;
}

interface IVenusFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
