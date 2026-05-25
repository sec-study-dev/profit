# F13-02: Balancer rETH rate-provider lag vs UniV3 rETH/WETH 0.01%

## Mechanism

A second rate-provider-lag arb against a **different** fresh-price venue
than F03-03 (which uses Curve). Here the fresh leg is the UniV3
**rETH/WETH 0.01% (fee tier 100) pool**
(`0x553e9c493678d8606D6a5BA284643dB2110Df823`), which re-prices on every
swap and is the deepest mainnet rETH AMM as of 2024.

Mechanics:

- **Balancer rETH/wETH MetaStable** pool
  (`0x1E19CF2D73a72Ef1332C882F20534B6519Be0276`, pool id
  `0x1e19cf2d73a72ef1332c882f20534b6519be0276000200000000000000000112`)
  prices rETH via a cached rate-provider that reads
  `RETH.getExchangeRate()`. The cache is refreshed every cache duration
  (default 1 hour) or on demand.
- **Rocket Pool** updates `getExchangeRate()` once per validator-balance
  consensus epoch (≈ daily). Each update bumps the rate by ~1-3 bps in a
  single block.
- During the stale window, Balancer over-values *or* under-values rETH
  depending on the direction of the jump. We handle both cases.

## Why it composes (differently from F03-03)

F03-03 unwinds against the **Curve rETH/ETH crypto pool**, which has its
own quasi-oracle (`last_prices`) that *also* lags. UniV3 has no
oracle-driven internal accounting — it re-prices purely from `liquidity`
and `sqrtPriceX96` updates as trades hit, so its quote is closer to the
true market.

Practically:
- Curve `last_prices` updates every trade with EMA smoothing; if no rETH
  trades have happened on Curve since the Rocket Pool rate bump, the
  Curve pool is *also* stale.
- UniV3 is purely AMM-bonded; whichever side of the curve has been
  bought during the day already reflects the market view.

This strategy is therefore a **better unwind venue choice** for shorter
stale windows where Curve hasn't yet caught up.

## Preconditions

- Block inside the stale window after a `RocketNetworkBalances` update.
- UniV3 rETH/WETH 0.01% pool TVL ≥ flash notional (it generally has
  >$30M and >5k WETH liquidity in 2024).
- Balancer flash fee == 0 (true since 2021).

## Strategy steps

1. Read `rFresh = RETH.getExchangeRate()`.
2. Read `rStale = BalancerRatedPool.getTokenRate(rETH)`.
3. If `rFresh > rStale`, Balancer under-values rETH:
   a. flashloan WETH from Balancer Vault.
   b. swap WETH → rETH on Balancer (cheap),
   c. swap rETH → WETH on UniV3 0.01% (market price, profit),
   d. repay flash.
4. If `rFresh < rStale` (rare negative-slashing case), reverse legs.
5. If spread < min threshold, skip.

## PnL math

Assume `rFresh = 1.115`, `rStale = 1.1135` (~13 bps stale, after a typical
oracle bump), `N = 500 WETH`:
- WETH → rETH on Balancer: out ≈ `500 / 1.1135 ≈ 449.04 rETH`.
- rETH → WETH on UniV3 1 bp: out ≈ `449.04 * 1.115 * (1 - 0.0001)`
  ≈ `500.63 WETH` gross.
- Balancer pool fee (4 bps): 0.2 WETH.
- UniV3 fee (1 bp): 0.05 WETH.
- Flash fee: 0 (Balancer Vault).
- Gas ≈ 320k * 25 gwei ≈ 0.008 WETH ≈ $26.
- **Net ≈ +0.38 WETH ≈ +$1,200 per 500 WETH** at this spread.

## Block pinned

- `FORK_BLOCK = 21_500_000` (Dec 2024 era; Rocket Pool oracle updates
  roughly daily, so this block selection only matters statistically).
  The PoC reads both rates and short-circuits if the spread is below
  `MIN_SPREAD_BPS = 5`.

## Risks

- **Spread < threshold**: short-circuited rather than reverting.
- **UniV3 price impact**: the rETH/WETH 1 bp pool is deep but a 500-WETH
  unwind moves the pool ~1 bp. Already accounted for in the math.
- **Cache refresh competition**: any vault swap on the Balancer rETH
  pool in the same block refreshes the cache.
- **Pool fee tier change**: Balancer rETH/wETH pool has historically
  been 4 bps. A fee hike would erase a 5-7 bps arb.

## Result

- Status: **theoretical / event-driven**. Mechanism is real and the
  trade is mechanically correct. Capturing requires archive-log scan
  for the first block after a `RocketNetworkBalances` rate update.
- PnL range: **+$100 to +$2,000 per 500 WETH** depending on stale
  width.
