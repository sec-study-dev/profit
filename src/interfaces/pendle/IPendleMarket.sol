// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Pendle Market (PT-YT-SY AMM). Most-used functions:
///   readTokens(), expiry(), isExpired(), totalActiveSupply(),
///   getRewardTokens(), redeemRewards(receiver), readState(router).
interface IPendleMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function expiry() external view returns (uint256);
    function isExpired() external view returns (bool);
    function totalActiveSupply() external view returns (uint256);
    function getRewardTokens() external view returns (address[] memory);
    function redeemRewards(address user) external returns (uint256[] memory);
    function userReward(address token, address user) external view returns (uint128 index, uint128 accrued);

    struct MarketState {
        int256 totalPt;
        int256 totalSy;
        int256 totalLp;
        address treasury;
        int256 scalarRoot;
        uint256 expiry;
        uint256 lnFeeRateRoot;
        uint256 reserveFeePercent;
        uint256 lastLnImpliedRate;
    }

    function readState(address router) external view returns (MarketState memory);
}
