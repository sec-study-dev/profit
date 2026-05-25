// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Lido withdrawal queue (NFT-based unstaking).
interface ILidoWithdrawalQueue {
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;
        uint256 amountOfShares;
        address owner;
        uint256 timestamp;
        bool isFinalized;
        bool isClaimed;
    }

    function requestWithdrawals(uint256[] calldata amounts, address owner)
        external
        returns (uint256[] memory requestIds);

    function requestWithdrawalsWstETH(uint256[] calldata amounts, address owner)
        external
        returns (uint256[] memory requestIds);

    function claimWithdrawal(uint256 requestId) external;
    function claimWithdrawals(uint256[] calldata requestIds, uint256[] calldata hints) external;

    function findCheckpointHints(uint256[] calldata requestIds, uint256 firstIndex, uint256 lastIndex)
        external
        view
        returns (uint256[] memory hintIds);

    function getLastCheckpointIndex() external view returns (uint256);
    function getLastFinalizedRequestId() external view returns (uint256);

    function getWithdrawalStatus(uint256[] calldata requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses);
}
