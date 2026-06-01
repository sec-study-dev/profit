# B07-01: PCS v3 USDT/WBNB 0.01% flash → Thena USDT/WBNB volatile pair arb

## Mechanism
Three BSC AMM primitives stacked into a single atomic cross-DEX arbitrage:

1. **PancakeSwap v3 USDT/WBNB 0.01% pool** — the single largest USDT/WBNB
   venue on BSC. UniswapV3 fork; `IUniswapV3Pool.flash()` exposes fee-only
   flashloans at the pool's swap fee (here 0.01% = 1 bp). A 200 WBNB
   ($120k) flash costs ~0.02 WBNB ($12).
2. **Thena WBNB/USDT volatile pair** — Solidly/Velodrome fork (ve(3,3)).
   The volatile (x·y = k) BNB/USDT pair has ~$2–4M reserves vs PCS v3's
   $20–40M, so spot mids lag during BNB price moves by 5–15 bps before LPs
   rebalance.
3. **Atomic arb** — borrow WBNB on PCS v3 → swap WBNB → USDT on Thena at
   the lagged (higher USDT/WBNB) price → swap USDT → WBNB on PCS v3 at the
   fresh price → repay flash. Edge = (Thena mid − PCS v3 mid)/PCS v3 mid
   − Thena 0.20% fee − PCS v3 0.01% fee (return leg) − PCS v3 1 bp flash
   fee − gas.

## Why it composes
- **Flash on PCS v3 is fee-only** — no external lender's surcharge (Balancer
  flash on BSC routes through a non-canonical bridge). The 0.01% pool is
  the cheapest BSC flash source for any USDT-denominated arb.
- **Thena & PCS v3 share no LPs.** Thena's bribe-driven gauge emissions
  keep LPs sticky even when Thena price diverges from PCS, because Thena
  LPs care about THE rewards, not slippage. This produces persistent (not
  just transient) spreads on BSC.
- **Same callback closes the loop.** UniV3-style flash + swap in the same
  transaction means MEV bots compete bp-for-bp but the strategy is robust
  to BSC's 3s block time — no positional risk.

## Preconditions
- Block where Thena vAMM has not been arbed in the last 1–2 blocks (gap
  ≥ 5 bp). Wave 3 should pin to a block right after a BNB price spike.
- Thena WBNB/USDT volatile pair exists and is not paused.
- PCS v3 0.01% WBNB/USDT pool has ≥ 200 WBNB of liquidity around the
  current tick.

## Strategy steps
1. Read PCS v3 `slot0().sqrtPriceX96` → compute `pcs_mid` (USDT per WBNB).
2. Read Thena pair `getReserves()` → compute `thena_mid` = r_USDT / r_WBNB.
3. If `thena_mid > pcs_mid` and spread ≥ MIN_SPREAD_BPS, fire flash.
4. In `pancakeV3FlashCallback`:
   - Swap FLASH_NOTIONAL_WBNB WBNB → USDT on Thena (1 hop, volatile route).
   - Swap the received USDT → WBNB on PCS v3 0.01% via `exactInput`.
   - Transfer `FLASH_NOTIONAL_WBNB + fee0` WBNB back to the pool.
5. Profit = (WBNB returned by step 2) − (WBNB borrowed + flash fee).

## PnL math
At a 10 bp Thena lag and 200 WBNB notional:
- Gross edge: 200 × 10/10_000 = 0.20 WBNB ≈ **$120**.
- Thena fee: 0.20% × 200 = 0.40 WBNB-equivalent ≈ **$240** *(this dominates
  small-spread cases — the strategy is only profitable when raw spread
  > Thena fee + PCS fee, i.e. ≥ ~22 bps gross)*.
- PCS v3 swap fee (return leg): 0.01% × 200 ≈ **$12**.
- PCS v3 flash fee: 0.01% × 200 ≈ **$12**.
- Net at 25 bps gap: 25 × 200 / 10_000 = 0.50 WBNB − fees ≈ **+$36**.

Edge scales with notional but is rate-limited by Thena's reserves (price
impact dominates above ~5% of reserve size). Realistic max single-shot
edge: **+$30–80 per fire at 20–40 bp spread**, daily hit rate ≈ 2–5
opportunities once spread filtering is tightened.

## Block pinned
**42_000_000** — sentinel value. Wave 3: re-pin to the first block after
a BNB candle ≥ 1% intraday where Thena pair has not synced.

## Addresses used
- `0x172fcD41E0913e95784454622d1c3724f546f849` — PCS v3 0.01% WBNB/USDT
  (`PCS_V3_WBNB_USDT_100`). token0 = WBNB, token1 = USDT.
- `0x20a304a7d126758dfe6B243D0fc515F83bCA8431` — Thena Router
  (`BSC.THENA_ROUTER`).
- `0x6BBcD4DC0eA9bF1bC78c4e3E7caF44b96f30A0eD` — Thena WBNB/USDT volatile
  pair (`THENA_WBNB_USDT_VOLATILE`). **Placeholder** — Wave 3 verify via
  `Router.pairFor(WBNB, USDT, false)` on pinned block.
- `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` — PCS v3 SwapRouter
  (`BSC.PCS_V3_ROUTER`).

## Risks
- **Thena reserve too small** — at 200 WBNB notional, price impact on a
  $3M Thena pool is ~7%, which eats the edge. Strategy must size flash
  to Thena reserves dynamically; current PoC is fixed-size as a witness.
- **Tick crossing** — large WBNB→USDT swap on PCS v3 0.01% may cross
  initialised ticks; with 0.01% tick spacing this is per-bp. Provide
  `sqrtPriceLimitX96 = 0` is unsafe in prod; PoC accepts it for clarity.
- **MEV competition** — every flash-arb bot on BSC watches the same pool.
  Realistic capture is fronts the first time we see the gap; otherwise
  searcher backruns. Strategy is therefore positional in expectation —
  fire on every block, expect <50% fill.
- **Thena pause / fee change** — ve(3,3) governance can alter the swap
  fee from 0.20% to 0.05–1.00%. Higher fee silently flips the edge.

## Result
Status: **theoretical** (BSC RPC not configured yet; PoC compiles and is
a no-op skip when spread < MIN_SPREAD_BPS). Expected PnL: **+$30–80 per
fire at 20–40 bp Thena lag**, dominated by Thena 0.20% fee.
