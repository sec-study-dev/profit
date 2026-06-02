# B02-08: 3-venue atomic MEV-style cycle on slisBNB (PCS v3 + Thena + Wombat, 3-mechanism)

## Mechanism (3 BSC DEX primitives)
1. **PancakeSwap v3** — leg A: WBNB → slisBNB on the 0.01 % tier (cheapest
   spot quote, often *under*-priced versus internal rate due to high tier
   competition from arbers using the tier purely for routing).
2. **Thena (ve(3,3) solidly)** — leg B: ~60 % of the slisBNB → WBNB on the
   *stable* solidly invariant pair. Thena's epoch-driven gauge votes
   periodically shift WBNB liquidity *into* this pair, making the leg B
   price unusually rich for an hour or two each Thursday.
3. **Wombat StableSwap LST pool** — leg C: remaining 40 % slisBNB → WBNB at
   Wombat's dynamic-asset-weight price. Wombat's weight rebalances on
   stake-flow, so the leg C price is correlated with (but not identical to)
   the Thena price.

Underneath, a *flash* is used as the capital provider but the flash source
is the **WBNB/USDT 0.05 % pool**, not the slisBNB/WBNB pair — this avoids the
"single-pool flash + same-pool swap" deadlock and lets leg A use the deepest
slisBNB/WBNB tier without restriction.

## Cycle
```
PCS v3 WBNB/USDT pool: flash(WBNB)
   |
   v
PCS v3 slisBNB/WBNB 0.01% tier: WBNB --> slisBNB            (leg A)
   |
   +---------------------+
   |                     |
   v 60%                 v 40%
Thena stable             Wombat LST pool
slisBNB --> WBNB         slisBNB --> WBNB                   (legs B, C)
   |                     |
   +---------+-----------+
             |
             v
       repay flash (WBNB + 5 bp)
```

End-of-block: all positions closed; PnL realised in pure WBNB.

## Why 3-mechanism (atomic)
A 2-venue cycle (PCS v3 in, Thena out) is a single mispricing surface — the
slisBNB/WBNB cross-DEX spread. Splitting the exit across **two** independent
venues with **different** invariants (Thena solidly cubic vs Wombat dynamic
weight) accomplishes two things:
1. Doubles the per-trade depth without doubling slippage (each exit absorbs
   half the slisBNB on its own respective curve).
2. Captures the **two-venue spread** as residual edge: when Thena
   solidly's mid is 1.0830 WBNB/slisBNB and Wombat's is 1.0790 WBNB/slisBNB,
   the cycle captures both, instead of executing entirely against the
   richer single venue and pushing it back into line.

This is genuinely 3-mechanism: PCS v3 (concentrated liquidity, x*y=k),
Thena (solidly cubic invariant), Wombat (dynamic-asset-weight curve). All
three have distinct fee structures and react to oracle moves on different
half-lives.

## Preconditions
- PCS v3 slisBNB/WBNB 100-bp pool has > 300 WBNB depth.
- Thena (WBNB, slisBNB, stable=true) pair has > 200 WBNB depth.
- Wombat LST pool has > 300 WBNB and > 300 slisBNB.
- All three venues quote slisBNB/WBNB simultaneously and their mid-prices
  span > 30 bp (the cycle margin floor).

## Block pinned
`FORK_BLOCK = 45_400_000` (placeholder). **TODO**: pin a Thursday-UTC block
right after Thena epoch flip + Lista oracle push.

## PnL math
Let `A` = PCS v3 100-bp slisBNB-per-WBNB (e.g. 0.934).
Let `B` = Thena stable WBNB-per-slisBNB (e.g. 1.083).
Let `C` = Wombat WBNB-per-slisBNB (e.g. 1.079).
Split fraction `s = 0.60`.

WBNB returned per WBNB flashed: `A * (s*B + (1-s)*C)`.
- `0.934 * (0.6*1.083 + 0.4*1.079) = 0.934 * 1.0814 ≈ 1.0100 WBNB`
- Gross edge: +100 bp; minus 5 bp flash + ~5 bp aggregate slippage → **+90 bp net**.
- On `N = 600 WBNB`: ~5.4 BNB ≈ **$3,240 per ticket**.

Realistic range:
- 8-20 bp net during inter-epoch windows ($288-$720/ticket).
- 35-60 bp net during Thena epoch flip + Wombat skew ($1,260-$2,160/ticket).
- 90-150 bp net at the perfect 3-venue dislocation (rare, $3k-$5k+).

## Risks
- **Front-running by MEV searchers**: this is the canonical MEV target
  surface. Production requires private RPC (bloXroute / Eden). Not relevant
  for offline PoC.
- **Stale Thena epoch**: if the gauge-vote-based liquidity shift has
  already been arbed away, leg B realises closer to leg A's mid and the
  cycle returns ~5 bp below flash fee. The PoC reverts in this case
  (negative PnL).
- **Wombat haircut surprise**: dynamic-weight haircut can spike on a
  skewed pool. Sized at 40 % share to limit impact.

## Result
- Status: theoretical / offline-first.
- Expected PnL: **+$280 – $3,200 per 600 WBNB ticket** (8-90 bp band).
