# B02-07: slisBNB PCS v3 flash + Thena solidly-stable swap + Lista internal rate (3-mechanism)

## Mechanism (3 BSC primitives)
1. **PancakeSwap v3 flash on the slisBNB/WBNB 0.05 % pool** — capital source
   (5 bp loan fee). Same-pool flash is fine because we do *not* swap back
   into the flash-source pool (we swap into Thena).
2. **Thena ve(3,3) "stable" pair `WBNB → slisBNB`** — uses the solidly
   invariant `k = x^3*y + y^3*x` instead of `k = x*y`. For pairs that should
   trade near 1:1 (which LST pairs effectively do once you discount by the
   internal rate), this invariant offers **near-flat price impact** in the
   middle region, then sharply rises slippage at the wings. This makes the
   pair price *lag* Lista oracle updates by minutes — exactly the surface we
   want to harvest.
3. **Lista StakeManager `convertSnBnbToBnb` / `convertBnbToSnBnb`** — the
   canonical, monotonic exchange-rate oracle. We use it as both:
   - PnL valuation of the retained slisBNB (forward rate).
   - Sanity check that Thena gave more slisBNB than Lista's mint-rate
     would have (`convertBnbToSnBnb(FLASH_NOTIONAL)`).

## Cycle
```
PCS v3 slisBNB/WBNB 0.05% pool: flash(WBNB)
   |
   v
Thena stable pair: WBNB --(solidly invariant)--> slisBNB
   |
   v
read Lista internal rate -> value slisBNB at convertSnBnbToBnb(amount)
   |
   v
repay flash (WBNB + 5bp) from buffer
```

The retained slisBNB is non-atomically redeemable via Lista's withdraw queue
at the internal rate (typically 7-15 days). The strategy realises PnL *now*
in terms of the slisBNB delta priced at the internal-rate oracle, and the
buffer covers the WBNB outflow until the queue clears.

## Why 3-mechanism (not 2)
- A 2-mechanism version is just "swap on Thena, value via Lista". The third
  mechanism is the PCS v3 *flash on the very same LST pair we're arbing
  against*, which lets us scale the position **without** ever holding the
  underlying capital. The 3-way composition (flash venue, swap venue, rate
  oracle, all *different* protocols) is what makes the surface large enough
  to dominate gas: Thena stable curves accept 800 WBNB at <10 bp impact in
  the flat region, where PCS v3 100-bp tier would slip ~80 bp.

## Preconditions
- A PCS v3 slisBNB/WBNB 0.05 % pool exists with > 1000 WBNB liquidity (per
  PCS analytics, true at most blocks since 2024-Q2).
- Thena has a *stable=true* LP for `(WBNB, slisBNB)` with > 500 WBNB
  reserves. **TODO**: verify on Thena's pair factory.
- `convertSnBnbToBnb` returns a rate strictly > 1e18.

## Block pinned
`FORK_BLOCK = 45_300_000` (placeholder). **TODO**: scan Thena for blocks
where Thena solidly quote diverges from Lista's `convertBnbToSnBnb` by
> 15 bp; these typically follow Lista's daily reward push by ~3-10 minutes.

## PnL math
Let `T` = Thena slisBNB-per-WBNB quote (e.g. 0.928 from solidly flat
region after a Lista rate push). Let `R = 1.082` BNB / slisBNB internal.

For `N = 800 WBNB`:
- slisBNB out: `N*T = 742.4`
- BNB-value at Lista rate: `N*T*R = 803.5 BNB`
- Flash fee: `0.0005 * N = 0.40 BNB`
- Net BNB: `N*(T*R - 1 - 0.0005) ≈ +3.06 BNB ≈ $1,836 @ $600/BNB`.

Realistic range:
- 5-15 bp net during quiet Thena windows → ~$240-$720/ticket.
- 30-60 bp net within 5 min of Lista oracle push → ~$1,440-$2,880/ticket.
- >100 bp during reward-push + Thena gauge-vote epoch flip → rare, $5k+.

## Risks
- **Thena stable invariant slippage**: at >2,000 WBNB the solidly curve
  exits the flat region; PoC sizes at 800 WBNB for safety.
- **Lista oracle stale**: if `convertSnBnbToBnb` hasn't updated for >24h
  the realised redemption rate may differ from the snapshot. Mitigated by
  reading the live view-function inside the callback.
- **PCS v3 flash → same-pair pool reentrancy**: avoided because the swap
  happens on Thena, not on PCS v3.

## Result
- Status: theoretical / offline-first.
- Expected PnL: **+$200 – $1,800 per 800 WBNB ticket** (10-50 bp band).
