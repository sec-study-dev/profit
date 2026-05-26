// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Euler V2 Ethereum Vault Connector (EVC).
/// @dev    Most-used: enableCollateral, enableController, disableController,
///         call (delegated multicall), batch.
interface IEVC {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }

    function enableCollateral(address account, address vault) external;
    function disableCollateral(address account, address vault) external;
    function enableController(address account, address vault) external;
    function disableController(address account) external;

    function getCollaterals(address account) external view returns (address[] memory);
    function getControllers(address account) external view returns (address[] memory);
    function isCollateralEnabled(address account, address vault) external view returns (bool);
    function isControllerEnabled(address account, address vault) external view returns (bool);

    function call(address targetContract, address onBehalfOfAccount, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory);

    function batch(BatchItem[] calldata items) external payable;

    function getCurrentOnBehalfOfAccount(address controllerToCheck)
        external
        view
        returns (address onBehalfOfAccount, bool controllerEnabled);
}
