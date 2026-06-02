// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Venus Comptroller (Core pool, Unitroller proxy).
/// @dev    Mirrors Compound v2 Comptroller surface. For Venus V4 isolated
///         pools (each pool has its own PoolRegistry + Comptroller) reuse the
///         same selectors against per-pool addresses.
interface IVenusComptroller {
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
    function exitMarket(address vToken) external returns (uint256);
    function markets(address vToken)
        external
        view
        returns (bool isListed, uint256 collateralFactorMantissa, bool isComped);

    function getAccountLiquidity(address account)
        external
        view
        returns (uint256 error, uint256 liquidity, uint256 shortfall);

    function getAssetsIn(address account) external view returns (address[] memory);
    function claimVenus(address holder) external;
    function venusAccrued(address holder) external view returns (uint256);
}
