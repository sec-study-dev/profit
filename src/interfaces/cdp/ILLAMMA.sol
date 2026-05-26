// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Curve crvUSD LLAMMA - the soft-liquidation AMM behind a crvUSD market.
/// @dev Most-used functions: get_p, p_oracle_up/down, active_band, bands_x/y, exchange.
interface ILLAMMA {
    function get_p() external view returns (uint256);
    function price_oracle() external view returns (uint256);
    function p_oracle_up(int256 n) external view returns (uint256);
    function p_oracle_down(int256 n) external view returns (uint256);
    function active_band() external view returns (int256);
    function active_band_with_skip() external view returns (int256);
    function min_band() external view returns (int256);
    function max_band() external view returns (int256);
    function bands_x(int256 n) external view returns (uint256);
    function bands_y(int256 n) external view returns (uint256);
    function user_state(address user) external view returns (uint256[4] memory);

    function exchange(uint256 i, uint256 j, uint256 in_amount, uint256 min_amount)
        external
        returns (uint256[2] memory);
    function get_dy(uint256 i, uint256 j, uint256 in_amount) external view returns (uint256);
    function get_dxdy(uint256 i, uint256 j, uint256 out_amount) external view returns (uint256, uint256);

    function A() external view returns (uint256);
    function coins(uint256 i) external view returns (address);
}
