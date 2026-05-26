// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice EigenLayer DelegationManager - delegate restaked shares to operators
///         and queue/complete withdrawals.
interface IEigenDelegationManager {
    struct SignatureWithExpiry {
        bytes signature;
        uint256 expiry;
    }

    struct QueuedWithdrawalParams {
        address[] strategies;
        uint256[] shares;
        address withdrawer;
    }

    struct Withdrawal {
        address staker;
        address delegatedTo;
        address withdrawer;
        uint256 nonce;
        uint32 startBlock;
        address[] strategies;
        uint256[] shares;
    }

    function delegateTo(address operator, SignatureWithExpiry calldata approverSignatureAndExpiry, bytes32 approverSalt)
        external;
    function undelegate(address staker) external returns (bytes32[] memory withdrawalRoots);

    function queueWithdrawals(QueuedWithdrawalParams[] calldata queuedWithdrawalParams)
        external
        returns (bytes32[] memory);

    function completeQueuedWithdrawal(
        Withdrawal calldata withdrawal,
        address[] calldata tokens,
        uint256 middlewareTimesIndex,
        bool receiveAsTokens
    ) external;

    function isDelegated(address staker) external view returns (bool);
    function delegatedTo(address staker) external view returns (address);
    function operatorShares(address operator, address strategy) external view returns (uint256);
    function isOperator(address operator) external view returns (bool);
}
