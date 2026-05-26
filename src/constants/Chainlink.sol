// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Chainlink price-feed address book
/// @notice Mainnet Chainlink aggregator addresses used by `test/utils/PriceOracle.sol`.
///         All USD-quoted feeds have 8 decimals. ETH-quoted feeds have 18 decimals.
library Chainlink {
    // ---- USD feeds (8 decimals) ----
    address constant ETH_USD = 0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419;
    address constant BTC_USD = 0xf4030086522a5beea4988f8ca5b36dbc97bee88c;
    address constant DAI_USD = 0xaed0c38402a5d19df6e4c03f4e2dced6e29c1ee9;
    address constant USDC_USD = 0x8fffffd4afb6115b954bd326cbe7b4ba576818f6;
    address constant USDT_USD = 0x3e7d1eab13ad0104d2750b8863b489d65364e32d;
    // TODO verify: stETH/USD aggregator on mainnet
    address constant STETH_USD = 0xcfe54b5cd566ab89272946f602d76ea879cab4a8;

    // ---- ETH-quoted feeds (18 decimals) ----
    // TODO verify: rETH/ETH aggregator
    address constant RETH_ETH = 0x536218f9e9eb48863970252233c8f271f554c2d0;
    // TODO verify: cbETH/ETH aggregator (Coinbase wrapped staked ETH)
    address constant CBETH_ETH = 0xf017fcb346a1885194689ba23eff2fe6fa5c483b;
}
