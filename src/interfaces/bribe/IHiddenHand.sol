// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Hidden Hand RewardDistributor (Redacted Cartel).
/// @dev    Most-used: claim(Claim[]). Each Claim is identifier (bytes32), account,
///         amount, merkleProof.
interface IHiddenHand {
    struct Claim {
        bytes32 identifier;
        address account;
        uint256 amount;
        bytes32[] merkleProof;
    }

    function claim(Claim[] calldata _claims) external;
    function rewards(bytes32 identifier) external view returns (address token, bytes32 merkleRoot, bytes32 proof, uint256 updateCount);
    function claimed(bytes32 identifier, address account) external view returns (uint256);
}
