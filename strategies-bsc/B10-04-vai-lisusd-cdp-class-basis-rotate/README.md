# B10-04 — lisUSD ↔ VAI CDP-class basis rotation (sign-flip carry)

## Family

B10 · Cross-stablecoin CDP basis (rotation branch).

## Thesis

B10-01 captures the **static** Lista-SF vs Venus-VAI-rate spread by always
minting VAI and selling for lisUSD. B10-04 is the **dynamic** version: it
treats the two rates as two time-series, computes the sign of the spread
each period, and *rotates* between two positional states:

- **State A** — debt in VAI, holding lisUSD. Pays Venus-VAI rate, earns
  whatever lisUSD-side yield exists. Profitable when `Lista_SF > Venus_rate`.
- **State B** — debt in lisUSD, holding VAI. Pays Lista SF, earns VAI-side
  yield. Profitable when `Venus_rate > Lista_SF`.

The rotation captures **both signs of the basis** through the cycle. Over a
full year, even if average spread is zero, the realised PnL is positive
because the strategy is always on the cheap side of the funding curve.

This is also a natural lead-up to a **paid-protocol-incentive** layer: when
Lista or Venus run boost campaigns on one side of the pair, the rotation
trigger is no longer just the rate spread but `rate_spread − incentive_yield`.

## Mechanism stack (per rotation event)

1. Read both rates:
   - `IVAIController.baseRateMantissa()` — Venus VAI annualised rate.
   - `IListaInteraction.borrowed(...)` snapshot delta vs prior period for
     the SF. (In production, also read `ILisUSDController.stabilityFee()`.)
2. Compute `spread_bps = lista_sf − venus_rate`.
3. If position is in State A and `spread_bps < -ROTATE_THRESHOLD`, flip:
   - Swap held lisUSD → VAI to repay Venus debt fully.
   - Withdraw collateral, re-deposit on Lista's CDP for slisBNB / asBNB.
   - Borrow lisUSD against the new collateral; hold + swap to VAI.
4. Symmetric flip for State B.

The unique structural feature is that **both legs are CDP debts on the same
chain**, so collateral rotation is just two `withdraw` + two `deposit` calls
against the same underlying BNB asset; no bridge / no synthetic.

## Block layout (offline-first PoC)

The PoC simulates **two rate epochs** within one test:

- Epoch 1 (days 0-30): State A holds. Lista SF > Venus rate. Carry =
  `(SF − VAI_rate) × 30 days`.
- Rotation event at t=30d: swap to State B.
- Epoch 2 (days 30-60): State B holds. Venus rate > Lista SF.
  Carry = `(VAI_rate − SF) × 30 days`.

Both epochs print positive PnL. The PnL block aggregates both into a single
`pnl_usd=` line.

## Why this is genuinely B10 (not B05 funding-flip)

B05-04 flips between USDe-funding and slisBNB-funding. B10-04 flips
between the **two native CDP-issued BSC stables** — same chain, same asset
class, no perp-funding leg. The structural surface is different: B10's
flip-cost is `2 × PCS_stable_swap_fee`, while B05's flip-cost is
`2 × bridge_fee + perp_close_slippage`.

## Status & PnL

- **Status:** offline-first. Compiles against the family-allowed interface
  surface. On-fork mode reads live Venus VAI rate but mocks the Lista SF
  read until B03 hardens the interface.
- **PnL model:** `notional = $500k`, two 30-day epochs, average spread
  magnitude = 250 bp annualised in each direction.
  - Epoch 1 carry: `500_000 × 250 bp × 30/365 = $1027`.
  - Rotation cost: `2 × 4 bp = 8 bp on $500k = $400`.
  - Epoch 2 carry: `500_000 × 250 bp × 30/365 = $1027`.
  - Net 60-day PnL ≈ **$1654**, annualised ≈ **2.0 % on notional**, with
    structurally low risk because debt and held asset are both stables at
    the same peg.

## TODO

- Tighten `ROTATE_THRESHOLD` once we have a real time series of the SF and
  VAI rate spreads. The 25 bp threshold used here is a starting guess.
- Layer protocol incentives (lisUSD MasterChef boost, Venus XVS rewards)
  into the rotation trigger.
- Add a *no-rotate* baseline so the family-level report can quantify the
  marginal alpha of the rotation vs the static B10-01 carry.
