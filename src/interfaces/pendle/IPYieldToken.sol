// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Pendle Yield Token (YT). Earns yield until expiry; expires worthless.
interface IPYieldToken is IERC20 {
    function SY() external view returns (address);
    function PT() external view returns (address);
    function expiry() external view returns (uint256);
    function isExpired() external view returns (bool);
    function factory() external view returns (address);

    function mintPY(address receiverPT, address receiverYT) external returns (uint256 amountPYOut);
    function redeemPY(address receiver) external returns (uint256 amountSyOut);
    function redeemPYMulti(address[] calldata receivers, uint256[] calldata amountPYToRedeems)
        external
        returns (uint256[] memory amountSyOuts);
    function redeemDueInterestAndRewards(address user, bool redeemInterest, bool redeemRewards)
        external
        returns (uint256 interestOut, uint256[] memory rewardsOut);

    function pyIndexCurrent() external returns (uint256);
    function pyIndexStored() external view returns (uint256);
    function getRewardTokens() external view returns (address[] memory);
}
