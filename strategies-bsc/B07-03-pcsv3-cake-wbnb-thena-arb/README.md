# B07-03: PCS v3 CAKE/WBNB 0.25% flash → Thena CAKE/BNB vAMM arb

## Mechanism
CAKE — PancakeSwap's gov token — is priced by PCS itself (v2, v3 0.25% and
0.05% tiers, plus a CAKE/WBNB StableSwap-style pool for tight bands).
Thena's CAKE/BNB pair exists for cross-protocol ve(3,3) bribes and is one
of the **less-frequently-arbed** mid-cap pairs on BSC.

1. **PancakeSwap v3 CAKE/WBNB 0.25%** — canonical mid-tail tier. Reasonable
   depth (~$2–5M TVL); fee tier is 25 bp so the flash fee per round-trip
   is 25 bp + 25 bp = 50 bp of the *notional*, but the strategy only pays
   the flash fee on the borrowed amount (not the swap leg twice).
2. **Thena CAKE/WBNB volatile pair** — ve(3,3) LPs farm THE for CAKE
   exposure; they don't actively rebalance. Mid lags PCS by 20–80 bps
   except after rebases or significant THE↔CAKE rotations.
3. **Atomic arb** — flash CAKE from PCS v3, sell on Thena at the lagged
   price, buy back on PCS v3 at fresh, repay. Required spread is the
   highest of any B07 strategy (≥ 100 bps) because the fee load is ~95 bps.

## Why it composes
- **Cross-protocol bribe layer** — CAKE is bribed on Thena gauges (CAKE
  emitters bid for THE votes), which means Thena LPs supply CAKE
  liquidity even at unfavourable spot prices. This is a structural reason
  for persistent mispricing.
- **PCS v3 flash on a 0.25% pool is still cheap** in absolute terms when
  the notional is sized correctly — 100k CAKE × 25 bp = 250 CAKE flash
  fee ≈ $625 of friction. Strategy needs ≥ 250 CAKE of arb edge to break
  even.
- **No external lender** — flash is pool-internal, no Aave or Balancer
  cross-protocol routing.

## Preconditions
- Block where Thena CAKE/BNB has not been re-balanced for several blocks
  (post-bribe-epoch is the highest-edge moment, weekly Thursday on Thena).
- PCS v3 0.25% pool has ≥ 100k CAKE liquidity around current tick.

## Strategy steps
1. Read PCS v3 mid and Thena mid (WBNB per CAKE).
2. If `thena > pcs + 100 bps`, fire flash for FLASH_NOTIONAL_CAKE.
3. Callback:
   - CAKE → WBNB on Thena vAMM.
   - WBNB → CAKE on PCS v3 0.25% via `exactInput`.
   - Transfer `100_000e18 + fee0` CAKE back to the pool.

## PnL math
100k CAKE notional ≈ $250k @ $2.50/CAKE. At 150 bps Thena lag:
- Gross edge: 100k × 150/10_000 = 1_500 CAKE ≈ **$3_750**.
- Thena 0.20% fee on 100k CAKE swap: 200 CAKE ≈ **$500**.
- PCS v3 swap 0.25% (return): 0.25% × 100k = 250 CAKE ≈ **$625**.
- PCS v3 flash 0.25% on 100k borrow: 250 CAKE ≈ **$625**.
- Net at 150 bps: **+$2_000**.

At 100 bps, ~$0 (break-even). At 200 bps: +$3_750. Realistic capture: 1–4
fires per week, around bribe-epoch transitions on Thena (Thursdays).

## Block pinned
**42_000_000** — sentinel. Wave 3: re-pin to a Thursday post-Thena-epoch
block where CAKE bribe payouts shift gauge balances.

## Addresses used
- `0x133B3D95bAD5405d14d53473671200e9342896BF` — PCS v3 0.25% CAKE/WBNB.
- `0xA5C6cD0E73Da9F1Ee0AE6e8b3aD0EE0Bf6Bb7666` — Thena CAKE/WBNB volatile
  pair. **Placeholder** — Wave 3 verify via Router.pairFor.
- `BSC.CAKE`, `BSC.WBNB`, `BSC.PCS_V3_ROUTER`, `BSC.THENA_ROUTER`.

## Risks
- **Thena CAKE pair drains** — at $250k notional on a $1–2M Thena pool,
  price impact reaches 15–25%, which can flip the edge negative even at
  large quoted spreads. Production must dynamic-size.
- **CAKE inflation / burn schedule** — CAKE emissions change quarterly;
  on emission cut days the price moves multi-percent in seconds, and
  Thena pairs lag for 1–2 blocks. Best fire window.
- **Thena bribe-week flips** — when ve(3,3) gauge weights re-set, LPs may
  exit en masse; pool liquidity can drop 30% in a single block, breaking
  size assumptions.
- **MEV** — moderate; CAKE/WBNB watched by ~5–8 searchers vs ~15 on the
  BNB/USDT pair. Single-shot capture: ~50%.

## Result
Status: **theoretical**. Expected PnL: **+$500–3_000 per fire at 120–200
bp Thena lag**, with edge concentrated around Thena epoch rollovers.
