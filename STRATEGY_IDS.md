# Strategy Family Ownership Table

This file is the **collision-prevention contract** for Wave 2. Each Wave 2
agent owns exactly one family ID `FXX` and may only write to paths matching
`strategies/FXX-*`. Do not edit another family's row or create files outside
your assigned family.

| ID  | Family name                  | One-line description                                                          | Owner             | Status   |
| --- | ---------------------------- | ----------------------------------------------------------------------------- | ----------------- | -------- |
| F01 | LST looping                  | Leverage looping of stETH / wstETH / rETH / cbETH / sfrxETH via Aave/Morpho.  | wave2-F01-agent   | pending  |
| F02 | LRT looping & restake        | EtherFi / Renzo / Kelp / Puffer leveraged restaking and points farming.       | wave2-F02-agent   | pending  |
| F03 | LST/LRT basis & peg          | Curve / Balancer peg arbitrage between LSTs/LRTs and ETH, withdrawal queues.  | wave2-F03-agent   | pending  |
| F04 | Maker DSR / sDAI / sUSDS     | DSR-anchored yield, PSM hops, sDAI/sUSDS leveraged via flash mint.            | wave2-F04-agent   | done     |
| F05 | crvUSD LLAMMA                | Soft-liquidation arbitrage and leveraged crvUSD borrows against LSTs.         | wave2-F05-agent   | done     |
| F06 | Liquity v1/v2 (LUSD/BOLD)    | Stability pool yield, redemption arbitrage, BOLD interest-rate dynamics.      | wave2-F06-agent   | pending  |
| F07 | Pendle PT / YT               | PT leveraged buy, YT yield speculation, SY composition with LST/LRT/stables. | wave2-F07-agent   | in-progress |
| F08 | Ethena USDe / sUSDe          | sUSDe carry, Pendle PT-sUSDe, looped sUSDe on Morpho/Aave.                    | wave2-F08-agent   | pending  |
| F09 | Morpho Blue isolated markets | Custom market loops, flashloan-bootstrap, idle-liquidity capture.             | wave2-F09-agent   | done     |
| F10 | Aave v3 / Spark / GHO        | E-mode loops, GHO mint-and-deploy, isolation-mode farming.                    | wave2-F10-agent   | pending  |
| F11 | Compound v3 + Fluid + Euler  | Cross-money-market rate arbitrage and isolated-vault composability.           | wave2-F11-agent   | pending  |
| F12 | Curve + Convex + bribes      | vlCVX vote-directed bribes, Votium/Hidden-Hand claim loops, gauge ecosystem.  | wave2-F12-agent   | done     |
| F13 | Balancer / Uniswap v3 LP     | Concentrated liquidity + boosted-pool stacking with LST primary tokens.       | wave2-F13-agent   | pending  |
| F14 | Synthetix atomic + sUSD      | sUSD/sETH atomic-swap arbitrage and synth-as-collateral composites.           | wave2-F14-agent   | pending  |
| F15 | EigenLayer native restake    | Direct EigenLayer strategy deposits, AVS rewards, LRT-vs-native comparisons.  | wave2-F15-agent   | pending  |
| F16 | Cross-CDP basis              | (Optional) Multi-CDP loops mixing GHO / crvUSD / DAI / LUSD as base debt.     | wave2-F16-agent   | done     |
| F17 | Yield-bearing stable carry   | (Optional) USDM / USDY / OUSD / syrupUSDC carry stacks vs sDAI/sUSDS baseline.| wave2-F17-agent   | done     |

## Rules

1. **One family, one agent.** Do not write `strategies/FYY-*` if you are not the owner of `FYY`.
2. **Status transitions.** When you start, change your row's status from `pending` to `in-progress`. When you finish, set it to `done`. Do not edit other rows.
3. **Numbering.** Within a family, number PoCs `01`, `02`, ... and keep them under ~5 per family unless the family is genuinely rich.
4. **No cross-family edits.** If a strategy genuinely spans families, file it under the family that *initiates* the position.
