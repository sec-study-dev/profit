# ETH PoC results WITH execution gas cost

A separate run that prices in each strategy's execution gas. The pre-existing
`reports/ETH_pnl_results.csv` (gas = 0) is left unchanged; this folder adds the
gas-inclusive view plus ETH-denominated figures.

Source: serial `forge test -vv --threads 1` over `strategies/` on a Tenderly
mainnet archive fork. Per-strategy gas telemetry emitted by
`StrategyBase._endPnL` (`gas_used`, fork-block `block.basefee`, `eth_usd_e8`).

## `ETH_cost_results.csv` columns
- `strategy`        - PoC id (= strategies/<id>/).
- `status`          - PASS / FAIL.
- `gas_used`        - EVM gas consumed by the strategy body (`_startPnL`..`_endPnL`).
- `gas_price_gwei`  - gas price used = the fork block's real `block.basefee`.
- `fee_eth`         - execution transaction fee in ETH = gas_used * basefee / 1e18.
- `eth_price_usd`   - ETH/USD at the fork block (for USD<->ETH conversion).
- `pnl_usd_pre_gas` - profit before gas (same basis as reports/ETH_pnl_results.csv net_usd).
- `gas_usd`         - fee_eth * eth_price_usd.
- `net_usd`         - gas-INCLUSIVE net = pnl_usd_pre_gas - gas_usd.
- `net_eth`         - gas-inclusive net profit in ETH = net_usd / eth_price_usd.
- `credibility`     - same CREDIBLE/OVERSTATED tag as the main report.

## Notes / caveats
- Gas price = each strategy's own fork-block base fee (1-20 gwei range), so fees
  are per-block realistic. (Priority fee/tip is not added; basefee only.)
- `gas_used` is measured under Foundry and INCLUDES cheatcode/harness overhead
  (vm.warp/roll, deal, prank) that a real transaction would not pay, so `fee_eth`
  is a slight OVER-estimate of true on-chain cost.
- `net_usd` here is gas-inclusive and therefore slightly lower than the gas-zero
  `net_usd` in reports/ETH_pnl_results.csv. Most positives remain OVERSTATED
  (deal()/modeled/position-equity) - read reports/README.md.
- Aggregate over the 127 PASS strategies with cost data: total fee ~= 1.82 ETH.
