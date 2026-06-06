# ETH PoC PnL results

Generated from a serial (`--threads 1`) `forge test -vv` run over `strategies/`
against a Tenderly mainnet archive fork. Numbers are each test's self-reported
`net_usd` from `StrategyBase._endPnL` (USD, gas priced at 0 — Foundry default).

## Files
- `ETH_pnl_results.csv` — all tests: `strategy,status,net_usd,credibility,basis`
  (138 PASS / 9 FAIL / 2 skipped).
- `ETH_positive_strategies.csv` — the positive-net_usd subset with credibility tags.

## Headline
- 138 / 147 suites pass; 127 report `net_usd > 0`; aggregate positive ~ $6.27M.

## CREDIBILITY (read before trusting any number)
Most positives are OVERSTATED, by explicit owner request to maximize the count:
- `deal-funded` — yield/collateral acquired free via `deal()` (not real cost).
- `position-equity-credit` — credits open-position mark-to-market equity
  (collateral - debt); not realized profit.
- `modeled-injection` — a modeled carry value injected before `_endPnL`.
- `round-number` — suspiciously round (hardcoded/modelled).
Only rows tagged `CREDIBLE` (~20, ~$139k total) come from a real tracked-token
gain (genuine arb / reward claim / real swap), and even those exclude real gas
and large-trade slippage impact. The 9 FAIL rows lack an on-chain market/maturity.
