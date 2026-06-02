# B07-07: PCS v3 flash → Pendle PT-sUSDe swap → Venus collateral & borrow

## Mechanism (3-mech)
Three BSC primitives composed atomically into a single leveraged carry:

1. **PancakeSwap v3 USDT/USDC 0.01% flash** — fee-only flashloan of
   USDT at 1 bp. Cheapest USDT flash source on BSC; same pool as
   B07-04 uses for USDC.
2. **Pendle PT-sUSDe market on BSC** — Pendle Finance's principal-token
   AMM. Discounted PT trades below par; buying PT and holding to
   maturity gives a fixed yield equal to the implied APY at trade
   time. We use `IPendleRouter.swapExactTokenForPt` to enter.
3. **Venus Core (vSUSDe + vUSDT)** — Compound v2-style money market.
   Supply PT-underlying (sUSDe) as collateral, borrow USDT back to
   close the flash. Position leaves a leveraged PT carry.

The arb captures the moment when **Pendle implied yield > Venus USDT
borrow APR + flash fee** by enough margin that the carry over time-to-
maturity dominates the entry cost.

## Why it composes
- **Pendle's PT pricing is independent** of Venus's borrow curve.
  Pendle prices PT off the YT market and SY pool; Venus prices borrow
  off utilisation. When sUSDe-as-collateral demand is low (so the
  collateral factor / haircut is generous) AND Pendle PT discount is
  wide (long-dated, low utilisation), the carry opens.
- **PCS v3 flash + atomic close = no funding risk** for the entry hop.
  We don't need to source USDT separately; the flash lets us go in
  fully levered and close at maturity (or by partial unwind earlier).
- **Three orthogonal failure modes** — Pendle market liveness, Venus
  collateral factor changes, PCS v3 flash availability. The PoC wraps
  Pendle and Venus calls in `try/catch` so a missing market gracefully
  unwinds (paying only the flash fee).

## Preconditions
- Pendle PT-sUSDe market on BSC live and not expired.
- Venus has a sUSDe / USDe collateral market (vSUSDe / vUSDe). If only
  vUSDe exists, the PoC's optional path redeems PT→sUSDe→USDe before
  supply (// TODO when Pendle BSC SY ABI is pinned).
- PCS v3 USDT/USDC 0.01% pool has ≥ 500k USDT liquidity.
- Pendle implied yield > Venus USDT borrow APR by MIN_CARRY_BPS (50).

## Strategy steps
1. Read `IPendleMarket.readState()` → derive `pt_implied_yield_bps` and
   `ttm_seconds`.
2. Read `IVToken(vUSDT).borrowRatePerBlock()` → annualise to bps.
3. Compute `edge_bps_over_ttm = (pt_yield − venus_borrow) × ttm /
   year`. Skip if ≤ flash fee + MIN_CARRY_BPS.
4. Flash USDT from PCS v3 USDT/USDC 0.01%.
5. Callback:
   - `Pendle.swapExactTokenForPt(USDT, ..., market, ...)`.
   - Supply PT (or redeemed sUSDe) to Venus as collateral.
   - `Venus.borrow(USDT, notional + flashFee)`.
   - Transfer borrowed USDT back to PCS v3 pool.

## PnL math
500k USDT notional, Pendle PT yield 12% APR, Venus USDT borrow 7%,
ttm = 90 days:
- Annualised carry: 5% = 500 bps.
- Pro-rated: 500 × 90/365 ≈ 123 bps over 90 days.
- Gross over ttm: 500k × 123/10_000 = **6_150 USDT** (≈ **$6_150**).
- PCS v3 flash fee (one-shot): 500k × 1/10_000 = **50 USDT**.
- Pendle swap fee (lnFeeRate-driven, typical 5–15 bps): **~$500**.
- Venus borrow fee (none on entry; accrued APR is embedded in borrow).
- **Net over ttm: ~$5_600.** Position must be held to maturity or
  rolled; PoC fires the entry only.

Hit rate: 1–3 entries per Pendle market lifecycle (a new market opens
roughly every 30–90 days on BSC Pendle).

## Block pinned
**42_000_000** — sentinel. Wave 3: pin to a block within the first
30% of a fresh PT-sUSDe market's lifespan, when implied yield is
typically 200–500 bps above Venus borrow.

## Addresses used
- `0x92b7807bF19b7DDdf89b706143896d05228f3121` — PCS v3 0.01% USDT/USDC
  (cheapest USDT flash source on BSC).
- `BSC.PENDLE_ROUTER_V4` = `0x8888...F946` — Pendle Router V4 (verify
  BSC deployment).
- `0x1d3000DF9F3B86E4D7d2Eb4C3a8e3A5A9d4f9a17` — Pendle PT-sUSDe BSC
  market. **Placeholder** — Wave 3 verify via Pendle's BSC market
  registry.
- `BSC.vUSDT` = `0xfD58...0255` — Venus vUSDT borrow market.
- `V_SUSDE_BSC` — currently `0x0` placeholder; PoC falls back to no-op
  Venus leg if the market doesn't exist at the pinned block. // TODO
  verify canonical vSUSDe BSC address.

## Risks
- **Pendle market liquidity** — PoC sizes 500k USDT into Pendle PT;
  shallow markets (< $2M) suffer 50–200 bps slippage that eats the
  carry. Production must size to ≤ 10% of market SY reserves.
- **Venus collateral factor change** — Comptroller can drop sUSDe CF
  mid-block, causing the borrow leg to revert (safe — atomic).
- **PT-sUSDe peg break** — if sUSDe drifts from USD or Ethena pauses
  redemptions, the PT mark-to-market collapses and Venus may
  liquidate before maturity.
- **3-mech surface = 3 failure modes** — PoC `try/catch`-wraps both
  Pendle and Venus legs and falls back to repaying from the original
  flash notional (loses only ~1 bp flash fee + gas).
- **MEV** — Pendle PT swaps emit unique selectors that searchers
  recognise; the flash+PT combo may be back-run.

## Result
Status: **theoretical**. Expected PnL when all three legs are live:
**+$3_000–10_000 over a 60–120 day carry** at 300–500 bps annualised
edge. Flash-fee gives ~95% leverage cheap; the carry compounds for the
duration of the PT market.
