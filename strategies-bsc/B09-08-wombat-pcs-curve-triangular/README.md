# B09-08: Triangular stable arb across Wombat + PCS Stable + PCS V3

## Mechanism
BSC hosts three meaningfully-distinct stableswap invariants. Each prices
USDT/FDUSD/USDC with a different curvature, so the three never agree perfectly:

- **Wombat** — dynamic-asset-weight haircut. Quote depends on `cov_in` and
  `cov_out`; pays bonuses on the side that needs liability restoration.
- **PCS StableSwap** — Curve-fork (constant-amplification) invariant.
  Locally linear in the equal-balance region; classic for FDUSD/USDC/USDT
  3pool routing.
- **PCS V3 (1bp tier)** — concentrated liquidity. Effectively
  zero-slippage when the LP positions cover the $1.0000 tick; small jumps
  at range boundaries.

The triangular path:

`USDT --[Wombat]--> FDUSD --[PCS Stable]--> USDC --[PCS V3]--> USDT`

The arb closes profitably when:
- Wombat's USDT side is over-allocated (`cov_USDT > 1.2`), so leg A pays a
  bonus to FDUSD takers.
- PCS Stable's FDUSD slot is *under-allocated* (FDUSD < 25% of 3pool TVL),
  so leg B's FDUSD->USDC is at-or-better than the flat curve.
- PCS V3 USDC/USDT 1bp tick is centered on parity (typical), so leg C is
  ~0 slippage minus the 1bp fee.

Flash-funded: the PCS V3 USDC/USDT 1bp pool serves *both* as the USDT flash
source (leg 0) AND as the leg-C USDC->USDT venue. This is intentional — the
arb's third leg already routes through that pool, so the flash repayment
happens "for free" as part of the loop.

## Why it composes
- **Three distinct invariants**: each has a unique pricing surface; the
  triangular spread is the disagreement among them.
- **Wombat dynamic-weight as the alpha source**: legs B and C are
  near-frictionless when their respective pools are balanced. The yield
  comes from Wombat's bonus when USDT is over-allocated.
- **Single-tx atomicity**: the flash + 3 swaps + repay are one tx; no
  inventory risk between legs.

## Mechanism count
**3-mechanism**: (1) Wombat dynamic-weight, (2) PCS StableSwap (Curve fork),
(3) PCS V3 concentrated. The flash is a funding primitive, not counted as a
separate mechanism (per the convention used in B09-01).

## Preconditions
- Wombat Main Pool `cov_USDT > 1.2`.
- PCS Stable 3pool has FDUSD listed AND `bal_FDUSD / D < 0.25`.
- PCS V3 USDC/USDT 1bp pool has active liquidity around tick 0 ($1.0000).
- All three pools have sufficient depth for $1M notional with <1 bp impact
  per leg.

## PnL math
At the documented preconditions:
- Leg A (Wombat USDT->FDUSD, cov_USDT=1.2): ~12 bp gross bonus, -5 bp
  haircut = +7 bp. PoC uses +8 bp for a slightly more favorable cov.
- Leg B (PCS Stable FDUSD->USDC, FDUSD under-allocated): 0 bp (under-
  allocation slightly favors FDUSD-out direction, but the favorable side
  here is FDUSD-in; PoC assumes the leg is at the flat 0 bp).
- Leg C (PCS V3 USDC->USDT 1bp tier, balanced tick): -1 bp.
- Flash fee: -1 bp on 1M USDT = $100.
- **Net per $1M: +8 bp -1 bp -1 bp = +6 bp gross of flash fee, -1 bp = +5 bp
  net = $500**.

Realistic dislocations:
- Quiet pools: 0-2 bp net -> unprofitable.
- Normal Wombat skew + PCS V3 well-stocked: 4-8 bp net -> $400-$800.
- Wombat stress (`cov_USDT > 1.4`): 12-20 bp net -> $1,200-$2,000.

## Block pinned
- `FORK_BLOCK = 46_200_000` (placeholder, ~Q4 2024). **TODO** pin a block
  satisfying all three preconditions simultaneously.

## Risks
- **PCS Stable FDUSD index unverified**: PoC assumes `PCS_IDX_FDUSD = 3`
  (4th coin). The canonical PCS 3pool is `BUSD=0, USDT=1, USDC=2`; FDUSD is
  more likely in a separate 2pool. **TODO verify** and refactor leg B if
  needed.
- **PCS V3 1bp tier may be illiquid at extremes**: range LPs concentrate
  near $1.0000 in normal times but pull liquidity during depeg scares; the
  leg-C slippage can blow out unexpectedly.
- **Three-way precondition rarity**: this is the chief risk — all three
  conditions must hold *simultaneously* for the arb to clear. In practice,
  the strategy is dormant most of the time.
- **Wombat pause / haircut bump**: governance can revise the haircut,
  inverting the leg-A direction.

## Result
- Status: **theoretical / offline-first**. Offline path documents the
  optimistic 6 bp gross / 5 bp net scenario.
- Expected PnL: **+$200 to +$2,000 per $1M flashed** in the favorable
  precondition window, **negative** in dormant periods (would not execute
  in production; off-chain trigger gates on cov + balance reads).

## TODO
- Verify the exact PCS Stable pool that lists FDUSD (separate 2pool vs
  4-coin 3pool extension) and fix indices.
- Add a precondition gate that reads `cov_USDT` from Wombat (via the asset
  `cash()` / `liability()` getters) and the PCS Stable balances.
- Pin a real block where all three preconditions hold.
- Add a variant that flashes USDC instead of USDT, in case PCS V3 has more
  USDC-side capacity on certain days.
- Consider routing leg B through a dedicated FDUSD/USDT 2pool if FDUSD is
  not in the canonical 3pool.
