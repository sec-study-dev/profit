# F14-04: Atomic exchange immediately after Chainlink oracle update

> Status: **theoretical-historical-replay / research-only**. This strategy is
> documented for completeness; it sandwiches a Chainlink oracle update and is
> **not safe to run in production** (it front-runs honest oracle infrastructure
> and amounts to an MEV-extractive attack on Synthetix peg defense). The PoC
> simulates the mechanic by forking at a known oracle-update block and emitting
> a delta line — it does **not** attempt to position before the update tx.

## Mechanism

Synthetix V2x's atomic exchanger reads `latestAnswer` from Chainlink at swap
time. The Chainlink ETH/USD aggregator pushes a new round whenever
`abs(newPrice - lastPrice) > 0.5%` *or* one hour has elapsed since the last
round, whichever comes first. The 0.5% deviation triggers fire on big moves,
which means:

1. At time `T`, ETH spot moves from $1800 to $1810 (+55 bp).
2. Chainlink's ETH/USD aggregator publishes a new round at block `B` with
   answer $1810.
3. The Curve TWAP used by Synthetix's `ExchangeRatesWithDexPricing` is a
   30-min EWMA — at block `B+0`, the TWAP is still anchored near $1800.
4. `exchangeAtomically(sUSD, X, sETH, ...)` reads:
   - `min(Chainlink_ETH, CurveTWAP_ETH) = min(1810, ~1800) = ~1800`.
   - User receives `X / 1800 * (1 - fee)` sETH — i.e. *pre-update* price.
5. Two blocks later the AMM has caught up: sETH on Curve sETH/ETH trades at
   the new $1810 spot.
6. Selling that sETH on Curve realizes $1810 / sETH; the round trip nets
   `(1810 - 1800) / 1800 = 55 bp` of edge minus fees.

The "sandwich" framing is misleading — the trade does not need to be in the
*same block* as the Chainlink update. The atomic exchanger uses
`min(chainlink, curveTWAP)` on the destination buy, so even one block after
the update the trade captures the wedge between the now-stale TWAP and the
fresh Chainlink. The edge closes as the TWAP catches up (~30 min half-life).

## Why it composes

This is the same arb as F14-01 but with a sharper trigger condition: rather
than relying on free-floating Chainlink-vs-Uniswap drift, this strategy
**positions immediately after a known Chainlink heartbeat or deviation update**.
It composes:

1. Chainlink ETH/USD aggregator — the *trigger oracle*.
2. Synthetix's `ExchangeRatesWithDexPricing.atomicTwapWindow` (configurable,
   ~30 min historically) — the *lagging clamp*.
3. Synthetix atomic exchange — the fair-value entry.
4. Curve sETH/ETH or sUSD 4pool — the open-market exit.

Compared to F14-01, the timing predicate (post-update) makes the edge
deterministic rather than random; in exchange it requires off-chain
infrastructure to detect the update event and submit the swap atomically.

## Preconditions

- Mainnet fork at a block immediately after a known ETH/USD Chainlink update
  with > 30 bp price step.
- Synthetix atomic exchange live for sETH and sUSD.
- `atomicTwapWindow > 0` (positive TWAP window means TWAP can lag).

## Strategy steps

1. Identify a historical block where Chainlink ETH/USD posted a >30 bp
   deviation update. For the PoC we use `FORK_BLOCK = 16_900_000` (late
   March 2023, period of high vol post-SVB recovery; this is a heuristic
   pick — Wave 3 sweeps will find better blocks).
2. Read the Chainlink aggregator: `(roundId, answer, ..., updatedAt)`. The
   PoC logs `block.number - updateBlock` to surface staleness for the run.
3. Fund the contract with 200_000 sUSD via deal.
4. `sUSD -> sETH` via Synthetix atomic exchange — locks in the *stale TWAP-
   clamped* price.
5. Sell sETH for ETH on Curve sETH/ETH (uses spot, post-update).
6. Wrap ETH -> WETH and swap WETH -> USDC on Uniswap v3.
7. Swap USDC -> sUSD on Curve sUSD 4pool (close the loop).
8. Log delta vs starting sUSD.

## PnL math

For a Chainlink ETH/USD step of `s` basis points (positive = up):

```
sETH_received = sUSD_in / P_pre * (1 - f_atom)
ETH_received  = sETH_received * (1 - f_curve_seth)
USDC_received = ETH_received * P_post * (1 - f_uni)
sUSD_back     = USDC_received * (1 - f_curve_susd)

PnL_bps  ≈ s - f_atom - f_curve_seth - f_uni - f_curve_susd
         ≈ s - 30 - 5 - 5 - 5
         ≈ s - 45 bps
```

Profitable iff `s > 45 bps`. Chainlink ETH/USD's 0.5% deviation trigger means
the *minimum* observed update has `s ≈ 50 bps` — i.e. *every* deviation-
triggered update is borderline profitable, and larger moves (>100 bps) are
unambiguously so.

## Block pinned

`16_900_000` — late March 2023. This is a heuristic choice; the PoC's value
is structural. Wave 3 should iterate across known Chainlink ETH/USD update
blocks (~24 / day during normal vol, ~50+ / day during stress) to find
maximum-edge entries. The PoC includes a `_logChainlinkStaleness` helper that
surfaces `updatedAt`, current `block.timestamp`, and the difference, so the
sweep can immediately rank blocks by recency.

## Risks

- **Ethical / production risk.** Front-running honest oracle infrastructure
  is corrosive to the protocol. This PoC is for research only.
- **Atomic exchange caps.** Bigger sizes get capped; the strategy is
  inherently throughput-limited.
- **TWAP rapidly catches up.** Half-life of the deviation is ~15 min; later
  inclusion forfeits the edge.
- **Symmetric direction.** If Chainlink stepped *down* and the trader entered
  `sUSD -> sETH`, they lose; production code must read the direction of the
  most recent update and pick the matching sUSD/sETH leg.

## Result
Status: theoretical-historical-replay
Expected PnL: ~(update_step_bps - 45bp) × notional on 200k sUSD per event (~$110 at 50 bp Chainlink deviation step, ~$1,100 at 100 bp; condition-dependent on update direction)

Captures the Chainlink-vs-TWAP wedge during the half-life immediately after
a Chainlink ETH/USD update. PoC mainly probes mechanics and logs the
direction/magnitude of the edge; profitability is condition-dependent on the
specific update event captured by the fork block.
