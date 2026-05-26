// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Convex Booster - registers Curve LPs into Convex's gauge proxy.
interface IConvexBooster {
    struct PoolInfo {
        address lptoken;
        address token;
        address gauge;
        address crvRewards;
        address stash;
        bool shutdown;
    }

    function deposit(uint256 pid, uint256 amount, bool stake) external returns (bool);
    function depositAll(uint256 pid, bool stake) external returns (bool);
    function withdraw(uint256 pid, uint256 amount) external returns (bool);
    function withdrawAll(uint256 pid) external returns (bool);
    function poolInfo(uint256 pid) external view returns (PoolInfo memory);
    function poolLength() external view returns (uint256);
    function earmarkRewards(uint256 pid) external returns (bool);
}

/// @notice Convex BaseRewardPool (per-pool rewards contract).
interface IConvexBaseRewardPool {
    function stake(uint256 amount) external returns (bool);
    function stakeFor(address account, uint256 amount) external returns (bool);
    function withdraw(uint256 amount, bool claim) external returns (bool);
    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);
    function getReward() external returns (bool);
    function getReward(address account, bool claimExtras) external returns (bool);
    function earned(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function extraRewardsLength() external view returns (uint256);
    function extraRewards(uint256 i) external view returns (address);
}
