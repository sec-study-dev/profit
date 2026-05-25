// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Mantle mETH (the token itself).
interface IMETH is IERC20 {
    function mETHToETH(uint256 mETHAmount) external view returns (uint256);
    function ethToMETH(uint256 ethAmount) external view returns (uint256);
}

/// @notice Mantle staking entrypoint (mints mETH from ETH).
interface IMantleStaking {
    function stake(uint256 minMETHAmount) external payable;
    function mETHToETH(uint256 mETHAmount) external view returns (uint256);
    function ethToMETH(uint256 ethAmount) external view returns (uint256);
    function unstakeRequest(uint128 methAmount, uint128 minETHAmount) external;
    function claimUnstakeRequest(uint256 unstakeRequestID) external;
}
