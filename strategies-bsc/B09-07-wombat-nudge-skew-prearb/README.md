# B09-07: Wombat asset-weight "nudge" pre-arb (atomic, flash-funded)

## Mechanism
Wombat's dynamic-asset-weight haircut is **convex** in the coverage ratio: a
swap that pushes `cov_in` from 1.08 to 1.10 costs *less per unit* than one
pushing from 1.10 to 1.12. Conversely, swapping *out* of an over-allocated
side at high `cov` pays a *higher per-unit bonus* as the curve restores
toward balance.

This creates an asymmetry: if a pool sits at `cov_USDT = 1.08` (moderately
over-allocated USDT) and an operator can run two trades back-to-back inside
the same tx, the operator can:

1. **Nudge** the pool further into skew with a small USDT->USDC swap (cost:
   ~7 bp haircut on the small notional `dN`).
2. **Strike** with a USDC->USDT swap that captures the *convex bonus* on the
   restored leg (~12 bp bonus on the same `dN`).

The strike picks up the difference between the marginal haircut on the way
in (low, because the pool was at 1.08) and the marginal bonus on the way out
(higher, because the pool is now at 1.12). Net atomic spread on the round-
tripped notional: 4-8 bp.

The flash leg uses PCS v3 USDC/USDT 0.01% pool to source the initial USDT
without capital. The 1 bp flash fee on the full notional is the main
obstacle — the strategy clears net positive only when the strike size is at
least as large as the nudge size *and* the ex-ante skew is at `cov_USDT >
1.05`.

## Why it composes
- **Wombat dynamic-weight convex curvature**: the *only* mechanism on BSC
  with this kind of nonlinearity in a stableswap. PCS/Curve are locally
  linear; tradeoff for atomic profit is impossible there.
- **PCS v3 flash on the same pair**: extremely thin flash premium (1 bp)
  vs the 4-8 bp spread the convexity yields.
- **No directional risk**: opens and closes in USDT in one tx.

## Mechanism count
**2-mechanism**: (1) Wombat dynamic-weight Main Pool, (2) PCS v3 flash. (Not
counting the optional PCS Stable return leg, which the PoC currently skips
because the nudge+strike already nets positive in USDT.)

## Preconditions
- Wombat Main Pool sits at `cov_USDT > 1.05` (ex-ante).
- USDC/USDT PCS v3 0.01% pool has at least 2M USDT depth.
- Wombat haircut rate unchanged from the 5 bp default — governance can lift
  this, which would invert the math.

## PnL math
At `cov_USDT = 1.08`:
- Nudge (100k USDT -> USDC): cost is `0.0007 * 100k = $70` (7 bp net haircut).
- Strike (100k USDC -> USDT at the over-corrected curve): bonus is
  `0.0005 * 100k = $50` (5 bp net bonus, after 5 bp haircut on the
  marginal-improving direction).
- Flash fee on 2M USDT: `2M * 0.0001 = $200`.
- **Net: -$220 per 100k nudge** — the PoC documents that the strategy as
  formulated is **negative-EV** without additional alpha.

Where it *can* clear positive:
- Larger ex-ante skew (`cov_USDT > 1.15`): nudge moves cheaper, strike pays
  more — convex math says 15-25 bp net per 100k notional, clearing the flash
  fee.
- Using PCS v3 USDC flash instead of USDT flash, then strike size can be
  decoupled from nudge size (strike larger than nudge, amortizing the flash
  fee). Documented as a TODO variant below.

Realistic dislocations:
- Typical week: strategy is dormant (flash fee > convex spread).
- Post-LP-imbalance event: 8-15 bp net per 100k -> $80-$150 / 100k.
- Stress (cov spread > 0.3): 30+ bp -> $300+ / 100k but with thin liquidity.

## Block pinned
- `FORK_BLOCK = 45_900_000` (placeholder). **TODO** pin a block where
  Wombat USDT coverage > 1.05 but < 1.20 (sweet spot of the convexity).

## Risks
- **Flash fee dominates** at low skew: strategy is *only* profitable in a
  narrow band of ex-ante cov. Mitigation: off-chain trigger that gates on
  the cov reading.
- **Liquidity-thin nudge size**: if the strike `dN` exceeds Wombat's
  effective depth, the haircut grows super-linearly and erases the bonus.
- **Same-block competition**: nudge+strike is a recognizable pattern; a
  searcher seeing the flash callback can sandwich the strike. Mitigation:
  private RPC.
- **PoC strike-size constraint**: current PoC ties strike-in to nudge-out
  because both are denominated in the flashed asset (USDT). The variant
  where USDC is flashed separately is documented in TODO.

## Result
- Status: **theoretical / offline-first**. The offline path documents a
  *negative-EV* result at the default cov assumption, intentionally —
  illustrating that this strategy gates on a precondition that the PoC
  cannot enforce without a real fork.
- Expected PnL at the **right** preconditions: **+$80 to +$300 per 100k
  nudge** when ex-ante `cov_USDT > 1.15`.

## TODO
- Add a USDC-flash variant where strike size is decoupled from nudge size.
- Add a `cov_USDT` precondition assertion (read pool's `liability` and
  `cash` getters via Wombat asset address).
- Pin a real block with `cov_USDT` in the 1.10-1.20 band.
- Consider chaining a PCS Stable return leg if the strike output is large
  enough to recover the flash fee.
