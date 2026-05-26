// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Votium MultiMerkleStash - biweekly bribe claim contract.
interface IVotium {
    struct ClaimParam {
        address token;
        uint256 index;
        uint256 amount;
        bytes32[] merkleProof;
    }

    function claim(address token, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof)
        external;
    function claimMulti(address account, ClaimParam[] calldata claims) external;
    function isClaimed(address token, uint256 index) external view returns (bool);
    function merkleRoot(address token) external view returns (bytes32);
    function update() external view returns (uint256);
}
