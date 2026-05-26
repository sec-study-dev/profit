// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Chainlink price-feed address book
/// @notice Mainnet Chainlink aggregator addresses used by `test/utils/PriceOracle.sol`.
///         All USD-quoted feeds have 8 decimals. ETH-quoted feeds have 18 decimals.
library Chainlink {
    // ---- USD feeds (8 decimals) ----
    address constant ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address constant USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    // TODO verify: stETH/USD aggregator on mainnet
    address constant STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;

    // ---- ETH-quoted feeds (18 decimals) ----
    // TODO verify: rETH/ETH aggregator
    address constant RETH_ETH = 0x536218f9E9Eb48863970252233c8F271f554C2d0;
    // TODO verify: cbETH/ETH aggregator (Coinbase wrapped staked ETH)
    address constant CBETH_ETH = 0xF017fcB346A1885194689bA23Eff2fE6fA5C483b;
}
