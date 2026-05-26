// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Generic Curve stableswap pool (int128 indices). Use for 3pool, stETH pool, etc.
interface ICurveStableSwap {
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver)
        external
        payable
        returns (uint256);
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external payable returns (uint256);
    function add_liquidity(uint256[3] calldata amounts, uint256 min_mint_amount) external payable returns (uint256);
    function remove_liquidity(uint256 _amount, uint256[2] calldata min_amounts) external returns (uint256[2] memory);
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount)
        external
        returns (uint256);
    function calc_token_amount(uint256[2] calldata amounts, bool is_deposit) external view returns (uint256);
    function balances(uint256 i) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
    function A() external view returns (uint256);
    function get_virtual_price() external view returns (uint256);
}

/// @notice Curve crypto pool (uint256 indices). Use for tricrypto2.
interface ICurveCryptoSwap {
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256);
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy, bool use_eth)
        external
        payable
        returns (uint256);
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount) external returns (uint256);
    function add_liquidity(uint256[3] calldata amounts, uint256 min_mint_amount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 token_amount, uint256 i, uint256 min_amount)
        external
        returns (uint256);
    function balances(uint256 i) external view returns (uint256);
    function coins(uint256 i) external view returns (address);
    function last_prices(uint256 k) external view returns (uint256);
    function price_oracle(uint256 k) external view returns (uint256);
    function price_oracle() external view returns (uint256); // 2-coin variant
    function get_virtual_price() external view returns (uint256);
}
