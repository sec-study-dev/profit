// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Aave V3 / Spark style flash-loan receiver.
interface IFlashLoanReceiverAave {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

/// @notice Aave V3 simple (single-asset) flashLoanSimple receiver.
interface IFlashLoanSimpleReceiverAave {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

/// @notice Balancer V2 flash-loan receiver.
interface IFlashLoanRecipientBalancer {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

/// @notice Maker DSS Flash (DAI flash-mint) receiver. ERC-3156 style.
interface IERC3156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32);
}

/// @notice Morpho Blue flash-loan callback.
interface IMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

/// @notice Uniswap V3 flash callback.
interface IUniswapV3FlashCallback {
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}
