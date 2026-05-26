// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Curve GaugeController - manages veCRV vote weights per gauge.
interface ICurveGaugeController {
    function vote_for_gauge_weights(address gauge_addr, uint256 user_weight) external;
    function gauge_relative_weight(address gauge_addr) external view returns (uint256);
    function gauge_relative_weight(address gauge_addr, uint256 time) external view returns (uint256);
    function get_gauge_weight(address gauge_addr) external view returns (uint256);
    function get_total_weight() external view returns (uint256);
    function vote_user_slopes(address user, address gauge)
        external
        view
        returns (uint256 slope, uint256 power, uint256 end);
    function last_user_vote(address user, address gauge) external view returns (uint256);
    function n_gauges() external view returns (int128);
    function gauges(uint256 i) external view returns (address);
    function gauge_types(address gauge) external view returns (int128);
}
