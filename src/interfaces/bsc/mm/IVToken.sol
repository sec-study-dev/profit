// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "src/interfaces/common/IERC20.sol";

/// @notice Venus vToken (Compound v2-style cToken). Used for both BEP20 and
///         native-BNB markets — vBNB overrides `mint()` to be payable.
interface IVToken is IERC20 {
    function underlying() external view returns (address);
    function exchangeRateStored() external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);

    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);

    function borrowBalanceStored(address account) external view returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
    function getCash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function supplyRatePerBlock() external view returns (uint256);
    function borrowRatePerBlock() external view returns (uint256);
}
