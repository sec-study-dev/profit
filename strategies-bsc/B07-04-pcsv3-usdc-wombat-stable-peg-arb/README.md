# B07-04: PCS v3 USDC/USDT 0.01% flash → Wombat USDC→USDT → PCS StableSwap USDT→USDC → repay

## Mechanism
Three independent stable AMMs each price USDC/USDT differently because they
use **different invariants**:

1. **PancakeSwap v3 USDC/USDT 0.01%** — concentrated-liquidity pool. LPs
   set the active band manually; effective price is the band mid-point
   while you stay within range, and a step-function once you cross ticks.
   Used here purely as the **fee-only flash source** (1 bp on the flash
   fee portion only, not the swap fee).
2. **Wombat Main Pool** — dynamic-asset-weight StableSwap. Each asset has
   a "coverage ratio" `C_i = cash_i / liability_i`; when `C_i < 1` (under-
   covered), Wombat's haircut for *adding* that asset goes UP and for
   *removing* it goes DOWN. This produces a systematic skew in USDC↔USDT
   pricing whenever the LP cash for one side has drained.
3. **PancakeSwap StableSwap** — classic Curve fork with amplification
   coefficient A (usually 100–1000 for stable basins). Static invariant;
   doesn't know about Wombat's coverage. Two-side balanced.

When Wombat's USDC is *over-covered* (C_USDC > 1) and USDT is *under-
covered* (C_USDT < 1), Wombat over-pays USDT for incoming USDC — i.e.
USDC→USDT on Wombat gives more USDT than the 1:1 par would imply by 5–
30 bps. We then dump that USDT back into PCS StableSwap (par-trading
venue), receive ~par USDC, and close the flash. Edge = Wombat under-
coverage premium − PCS StableSwap 0.04% fee − PCS v3 1 bp flash fee.

## Why it composes
- **Three different stable invariants → persistent mispricing.** Each
  pool's LPs are mutually unaware: PCS StableSwap LPs target a curve
  shape, Wombat LPs target coverage rebalance, PCS v3 LPs target tick
  bands. No single LP arbs all three.
- **PCS v3 0.01% as flash source is unbeatable** for stable arbs — 1 bp
  fee on $1M is $100, vs. Aave's 5 bp ($500) or Balancer's 0 bp but
  forced multi-hop routing. PCS v3 keeps the cycle two-hop and atomic.
- **All-stable cycle = no price-impact tail risk** in the asset-price
  sense. Slippage is purely from invariant curvature, which is known
  ex-ante from `quotePotentialSwap` / `get_dy`.

## Preconditions
- Block where Wombat's USDC and USDT coverage ratios are imbalanced by
  ≥ 8 bps in our favored direction. Most common post-Binance-treasury
  deposits/withdrawals which lopsidedly add stables.
- PCS StableSwap 3-pool is live and not paused.
- PCS v3 0.01% USDC/USDT pool has ≥ 1M USDC liquidity around tick 0.

## Strategy steps
1. Quote Wombat USDC→USDT for FLASH_NOTIONAL_USDC.
2. Quote PCS StableSwap USDT→USDC for that USDT.
3. Compute net: `(stableswap_usdc_out) − (notional + pcsv3 flash fee)`.
4. If edge ≥ MIN_SPREAD_BPS, fire `pool.flash()` on PCS v3 for the USDC
   side only.
5. Callback:
   - Approve + `Wombat.swap(USDC, USDT, notional, 1, this, deadline)`.
   - Approve + `PCS_StableSwap.exchange(0, 1, usdtOut, 1)` to USDC.
   - Transfer `notional + flash_fee` USDC back to the pool.

## PnL math
1M USDC notional, Wombat under-coverage of USDT by 15 bps:
- Wombat USDT out: 1M × (1 + 15/10_000) − 4 bps Wombat haircut ≈
  1_001_100 USDT.
- PCS StableSwap USDC out: 1_001_100 × (1 − 4 bps) ≈ 1_000_700 USDC.
- PCS v3 flash fee: 1M × 1/10_000 = 100 USDC.
- **Net PnL: 1_000_700 − 1_000_100 ≈ +600 USDC ≈ +$600.**

At an 8 bps imbalance: roughly break-even. At 30 bps (rare, treasury
event): +$2_000+. Hit rate: ~daily after large Binance OTC moves;
~weekly otherwise.

## Block pinned
**42_000_000** — sentinel. Wave 3: pin to a block right after a large
single-token Wombat deposit (the kind that drops one coverage ratio
> 1.05 and another < 0.95).

## Addresses used
- `0x92b7807bF19b7DDdf89b706143896d05228f3121` — PCS v3 0.01% USDT/USDC
  pool (cheapest BSC flash source for stables).
- `BSC.WOMBAT_MAIN_POOL` = `0x312B...5fb0` — Wombat Main Pool (dynamic
  StableSwap).
- `0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C` — PCS StableSwap 3-pool
  USDC/USDT/BUSD. **Placeholder** — Wave 3 verify against the PCS
  StableSwap factory.
- `BSC.USDC`, `BSC.USDT`, `BSC.PCS_V3_ROUTER`.

## Risks
- **Wombat coverage ratio inversion mid-tx** — large flash on Wombat
  shifts USDC coverage materially, which flips the haircut against us.
  Production must limit notional to ≤ 1% of Wombat USDC LP cash; PoC
  uses fixed 1M.
- **PCS StableSwap index mismatch** — token index (i, j) is pool-config
  specific; the placeholder USDT=0, USDC=1 must be verified. Wrong index
  = wrong asset swapped = strategy reverts (safe) or sends wrong asset
  (loss). Production must call a `coins(i)` getter to confirm.
- **Wombat haircut spike** — if a third party drains USDC from Wombat
  in the same block, our haircut jumps and the cycle reverts on the
  PCS v3 repayment check (good — atomic, no loss). Lost only gas.
- **PCS StableSwap paused** — newer PCS StableSwap deploys have a guardian
  pause; check `paused()` view if available.

## Result
Status: **theoretical**. Expected PnL: **+$300–2_000 per fire at 10–30
bp Wombat coverage imbalance**, with very low MEV competition because
the three-DEX path is non-obvious to single-pool searchers.
