// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Morpho Blue singleton. Each market is identified by Id (keccak256 of MarketParams).
interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    function createMarket(MarketParams calldata marketParams) external;

    function supply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function borrow(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);

    function supplyCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;

    function withdrawCollateral(
        MarketParams calldata marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256);

    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    function accrueInterest(MarketParams calldata marketParams) external;

    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function isAuthorized(address authorizer, address authorized) external view returns (bool);

    function position(bytes32 id, address user) external view returns (Position memory);
    function market(bytes32 id) external view returns (Market memory);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
}
