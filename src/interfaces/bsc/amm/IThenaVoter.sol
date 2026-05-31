// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Thena Voter (ve(3,3) gauge + bribe controller).
interface IThenaVoter {
    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata weights) external;
    function reset(uint256 tokenId) external;
    function gauges(address pool) external view returns (address gauge);
    function bribes(address gauge) external view returns (address internalBribe, address externalBribe);
    function claimBribes(address[] calldata bribes_, address[][] calldata tokens, uint256 tokenId) external;
    function claimRewards(address[] calldata gauges_, address[][] calldata tokens) external;
    // TODO: confirm method names; some Thena forks renamed `bribes` to
    //       `external_bribes` / `internal_bribes`.
}
