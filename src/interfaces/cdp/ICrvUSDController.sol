// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Curve crvUSD Controller - per-market controller managing user loans.
interface ICrvUSDController {
    function create_loan(uint256 collateral, uint256 debt, uint256 N) external;
    function add_collateral(uint256 collateral, address _for) external;
    function remove_collateral(uint256 collateral) external;
    function borrow_more(uint256 collateral, uint256 debt) external;
    function repay(uint256 _d_debt) external;
    function repay(uint256 _d_debt, address _for) external;
    function liquidate(address user, uint256 min_x) external;
    function liquidate_extended(address user, uint256 min_x, uint256 frac, bool use_eth, address callbacker, uint256[] calldata callback_args) external;

    function user_state(address user) external view returns (uint256[4] memory);
    function health(address user) external view returns (int256);
    function health(address user, bool full) external view returns (int256);
    function debt(address user) external view returns (uint256);
    function loan_exists(address user) external view returns (bool);
    function amm() external view returns (address);
    function collateral_token() external view returns (address);
    function max_borrowable(uint256 collateral, uint256 N) external view returns (uint256);
    function min_collateral(uint256 debt, uint256 N) external view returns (uint256);
}
