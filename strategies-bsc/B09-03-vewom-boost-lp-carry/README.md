# B09-03: veWOM lock + Wombat LP boosted-carry positional

## Mechanism
Wombat's reward emissions to LPs are split between a **base rate** (per-asset
TVL share) and a **boosted rate** (modulated by `boostMultiplier`, which is a
function of `veWOM_balance / LP_balance` for that user). The boost curve is
sub-linear but the marginal $1 of veWOM still adds 10-15% to a small LP's
emission rate, and the position composes:

- **Lock leg**: convert `WOM` to `veWOM` via `MasterWombat.lockVeWOM(amount,
  lockDays)`. Longer locks have larger multipliers; 365-day lock typically
  yields ~3.6x veWOM per WOM.
- **LP leg**: deposit USDT or USDC into Wombat Main Pool to receive LP tokens,
  then stake those LPs in MasterWombat.
- **Vote leg** (optional): allocate veWOM votes across Wombat sidecar pools
  (BNB pool, slisBNB pool, USDe pool) to direct emissions to the pool where
  the user is already an LP.

Net carry composition for a holder with `V` veWOM and `L` LP value in pool i:

```
yield_i = baseAPR_i + boostAPR_i(V/L_i) + voteBonusAPR_i(votes_i / totalVotes_i)
```

## Why it composes
- **veWOM**: non-transferable, monotonically accruing over the lock; provides
  a "convex" boost relative to vanilla LPing.
- **Wombat asset-weight LP**: deposit/withdraw in a *single* asset (no need to
  pair). Coverage-ratio mechanics mean the LP avoids impermanent loss within
  the stable basket (idealized).
- **Vote bribes**: Equilibria, Magpie, and Wombex periodically pay bribes on
  veWOM votes; this PoC ignores bribes but the math accommodates them as a
  multiplier on the vote leg.

## Preconditions
- WOM token bought at or below market (PoC assumes a fixed entry price for
  PnL accounting). // TODO: integrate a price source if Wombat MasterWombat
  view is available.
- Wombat MasterWombat / veWOM contracts deployed at known addresses.
  **TODO verify** the canonical addresses; not in `BSC.sol` yet, so the PoC
  uses stub `address(0x...)` and offline-mode accounting.
- Lock period covers the PoC's multi-block simulation (`vm.warp` advances by
  30 days).

## PnL math
Inputs:
- LP notional `L = 1_000_000 USDT`.
- WOM bought for the lock: `W = 250_000 WOM` at $0.10 each = $25k.
- Lock 365 days -> veWOM ~ `3.6 * 250k = 900_000 veWOM`.

Under typical post-2024 Wombat boost params:
- Base APR on USDT LP: ~3-5% in WOM + ~1% in trading-haircut fees.
- Boost factor at `V/L = 0.9`: ~2.2x on the WOM emissions leg.
- Effective WOM APR: 3% * 2.2 = 6.6%. Trading-fee APR: 1%.
- Total APR on the LP: ~7.6% in USD-equivalent.

Over 30 days:
- LP carry: `1_000_000 * 7.6% * 30/365 = $6,247`.
- veWOM time decay: 30 days of lock burns ~ 30/365 of the veWOM balance, but
  total locked WOM stays constant (just the multiplier decays). For a 365-day
  lock, after 30 days the remaining lock is 335 days; multiplier ~ 3.3x.
- Net 30d PnL (LP carry only): ~$6,200.
- Net 30d PnL minus WOM mark-to-market risk (assumed flat in PoC): same.

Comparison to vanilla USDT LP (no veWOM):
- Base 4% APR -> 30d = $3,288. Boost adds ~$2,900 / 30 days for $25k of WOM.
- Implied veWOM IRR: $2,900 / $25k = 11.6% in 30 days -> annualized ~ 140%
  (ignoring decay and re-lock costs).

## Block pinned
- `FORK_BLOCK_START = 45_000_000` (lock + LP open).
- `FORK_BLOCK_END = 45_900_000` (~30 days later; ~3s blocks * 30d ≈ 864k).
- **TODO**: pick real blocks with consistent WOM price.

## Risks
- **WOM token price**: PoC assumes flat $0.10. A 20% drawdown wipes the
  boost premium on a 30d horizon. In production, this is a position-sizing
  risk, not a mechanism flaw.
- **MasterWombat selector changes**: Wombat rolled out V3 in 2024; older
  PoCs referencing V2 selectors will fail.
- **Re-lock vs let-decay**: at 90% boost utilization, the optimal policy is
  to top-up the lock weekly; PoC simulates a single 30-day hold for
  simplicity.
- **Pool de-listing**: if Wombat votes off the USDT asset, the LP loses
  emissions overnight. Hedge: split across USDT, USDC, BUSD assets.

## Result
- Status: **theoretical / offline-first** (no Wombat MasterWombat interface
  in repo; the PoC is multi-block positional accounting only).
- Expected 30d PnL on $1M LP + $25k WOM: **+$6,000 to +$7,500** (LP base +
  boosted emissions + fee share, minus WOM price risk).
