// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Convex vote-locked CVX (16-week lock).
interface IVlCVX {
    struct LockedBalance {
        uint112 amount;
        uint112 boosted;
        uint32 unlockTime;
    }

    function lock(address _account, uint256 _amount, uint256 _spendRatio) external;
    function processExpiredLocks(bool _relock) external;
    function getReward(address _account, bool _stake) external;
    function delegate(address newDelegatee) external;
    function delegates(address account) external view returns (address);

    function lockedBalances(address _user)
        external
        view
        returns (uint256 total, uint256 unlockable, uint256 locked, LockedBalance[] memory lockData);

    function balanceOf(address _user) external view returns (uint256);
    function lockedBalanceOf(address _user) external view returns (uint256);
    function pendingLockOf(address _user) external view returns (uint256);
    function balanceAtEpochOf(uint256 _epoch, address _user) external view returns (uint256);
    function totalSupplyAtEpoch(uint256 _epoch) external view returns (uint256);
    function epochCount() external view returns (uint256);
    function epochs(uint256 i) external view returns (uint224 supply, uint32 date);
}
