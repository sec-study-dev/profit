// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Compound V3 Comet (per-base-asset market).
interface IComet {
    struct UserBasic {
        int104 principal;
        uint64 baseTrackingIndex;
        uint64 baseTrackingAccrued;
        uint16 assetsIn;
        uint8 _reserved;
    }

    function supply(address asset, uint256 amount) external;
    function supplyTo(address dst, address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function withdrawTo(address to, address asset, uint256 amount) external;

    function baseToken() external view returns (address);
    function baseScale() external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function getSupplyRate(uint256 utilization) external view returns (uint64);
    function getBorrowRate(uint256 utilization) external view returns (uint64);
    function totalSupply() external view returns (uint256);
    function totalBorrow() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceOf(address account) external view returns (uint256);
    function collateralBalanceOf(address account, address asset) external view returns (uint128);
    function userBasic(address user) external view returns (UserBasic memory);
    function isBorrowCollateralized(address account) external view returns (bool);
    function isLiquidatable(address account) external view returns (bool);

    function accrueAccount(address account) external;
    function absorb(address absorber, address[] calldata accounts) external;
    function buyCollateral(address asset, uint256 minAmount, uint256 baseAmount, address recipient) external;
}
