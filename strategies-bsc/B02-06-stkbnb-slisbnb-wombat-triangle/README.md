# B02-06: Triangular stkBNB ↔ WBNB ↔ slisBNB cross-LST arb on Wombat + PCS v3 (3-mechanism)

## Mechanism (3 distinct BSC primitives)
1. **PancakeSwap v3 single-pool flash** (WBNB/USDT 0.05 % tier) — capital
   provider for the 500-WBNB ticket; flash fee 5 bp.
2. **Wombat StableSwap LST-class pool** — uses *dynamic asset weight* (the
   per-asset deviation from target weight scales the slippage curve). Right
   after a pSTAKE oracle push, Wombat's stkBNB asset weight has not yet
   rebalanced, so WBNB → stkBNB quotes 4-15 bp cheap.
3. **Lista StakeManager `convertSnBnbToBnb`** — the canonical, monotonic
   redemption price for slisBNB. We don't redeem; we value the slisBNB
   end-of-cycle balance at this rate (the only rate Lista honors 1:1).

A 4th mechanism is implicitly involved (pSTAKE's `IStkBNB.exchangeRate`) but
it is only read as a diagnostic — we do *not* mint or burn via the pSTAKE
StakeManager in this atomic flow.

## Cycle
```
flash WBNB (PCS v3 mechanism #1)
   |
   v
Wombat LST pool: WBNB -> stkBNB           (mechanism #2: Wombat dynamic weight)
   |
   v
PCS v3 100-bp tier: stkBNB -> slisBNB     (mechanism #2b: cross-LST direct pair)
   |
   v
value slisBNB at Lista internal rate      (mechanism #3: Lista StakeManager)
   |
   v
repay flash (WBNB) from buffer
```

The economic point: the slisBNB we end up holding can be redeemed via Lista's
withdraw queue for `convertSnBnbToBnb(amount)` BNB. If that BNB amount, less
the 5 bp flash fee and Wombat haircut, exceeds the flash notional, the
position is net long an LST at a discount to internal rate.

## Why 3-mechanism (not just 2)
A 2-mechanism version would be "buy slisBNB on Wombat → value at Lista rate"
(B02-01 territory). The *cross-LST* hop through stkBNB is the third
mechanism: it converts the Wombat dislocation (which is on stkBNB) into
slisBNB (which is what Lista will redeem) via a *separate* PCS v3 pool. Each
of the three legs has independent failure modes (Wombat haircut, PCS v3
liquidity, Lista rate freshness) and the surface only closes when *all
three* line up.

## Preconditions
- Wombat LST pool exists with WBNB↔stkBNB and is shallow-skewed.
- PCS v3 stkBNB/slisBNB 100-bp pool has at least the 500-stkBNB liquidity
  needed to absorb the leg-2 trade with <10 bp slippage.
- pSTAKE oracle was recently pushed (Wombat lag window is 1-30 min).
- Lista StakeManager is operational and `convertSnBnbToBnb` is non-stale.

## Block pinned
`FORK_BLOCK = 45_200_000` (placeholder). **TODO**: pin a block within 15
minutes of a pSTAKE `updateExchangeRate` event where the Wombat stkBNB asset
weight delta vs target is > 8 bps.

## PnL math
Let `W` = Wombat WBNB → stkBNB rate (e.g. 0.918), `X` = PCS v3 stkBNB →
slisBNB rate (e.g. 1.011), `R_L` = Lista internal slisBNB → BNB rate
(e.g. 1.082).

End-of-cycle BNB-equivalent per WBNB flashed: `W * X * R_L`.
- 0.918 × 1.011 × 1.082 ≈ **1.0042 BNB / WBNB** → 42 bps gross.
- Less 5 bp flash, ~3 bp Wombat haircut, ~1 bp PCS swap slippage → **+33 bp net**.
- On 500 WBNB notional: ~1.65 BNB ≈ **$990 per ticket**.

Realistic range:
- 8-20 bp net during quiet pSTAKE windows (~$240-$600/ticket).
- 30-60 bp net within 5 min of a pSTAKE reward push (~$900-$1,800/ticket).
- >100 bp during reward-push + slisBNB dump coincidence (rare; ~$3,000+).

## Risks
- **Wombat haircut surprise**: dynamic-weight haircut can exceed the
  modelled value if the pool was already skewed by a competing arber.
- **PCS v3 cross-LST pool depth**: stkBNB/slisBNB direct pair may have <100
  WBNB-equivalent of liquidity; the test reverts cleanly if leg 2 slips
  more than the buffer.
- **Lista queue tax**: Lista may charge 1-10 bp on `requestWithdraw`; PoC
  values slisBNB at the un-taxed rate (worst-case bound is `rate * 0.999`).
- **Three-way race**: searchers on private RPCs may consume one of the
  three legs before our flash lands. Production needs a private mempool.

## Result
- Status: theoretical / offline-first.
- Expected PnL: **+$200 – $1,800 per 500 WBNB ticket** (40 bp band).
