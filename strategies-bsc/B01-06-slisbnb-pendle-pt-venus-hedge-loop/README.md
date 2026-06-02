# B01-06: slisBNB Venus loop + Pendle PT-slisBNB rate hedge (3-mechanism)

## Mechanism — three BSC primitives stacked
1. **Lista DAO slisBNB** — non-rebasing BNB LST. BNB → slisBNB via
   `ListaStakeManager.deposit{value}()`. The stake-rate accrues to the
   slisBNB exchange rate.
2. **Venus Core pool** — supply slisBNB as collateral (`vslisBNB.mint`),
   borrow native BNB (`vBNB.borrow`), recycle. Standard recursive leverage
   on the slisBNB → BNB carry.
3. **Pendle BSC PT-slisBNB** — divert a small **15 %** slice of each
   iteration's borrowed BNB into PT-slisBNB at the prevailing market
   discount. PT pins the *future* slisBNB rate at a fixed level: if the
   Lista stake APY compresses while the position is open, the PT's
   embedded carry compensates for the lost loop yield.

This is a **3-mech positional strategy** (not atomic): the PT leg is held
to or near maturity. It's the natural rate-hedge overlay on B01-01.

## Why the hedge improves expected value
The pure B01-01 loop has positive *expected* PnL only when
`slisBNB stake APY > vBNB borrow APR`. The biggest tail-risk is **carry
compression**: Lista validators rotate, slisBNB stake APY drops from
~4 % to ~2.5 %, vBNB borrow stays put at ~2.2 %, and the levered position
turns barely positive — then negative once gas + fees are netted.

By pre-buying PT-slisBNB *with borrowed BNB*, we lock the spread on the
hedged slice:
- If stake APY falls → PT mark-up (PT was bought at the old higher implied
  rate) covers the lost loop yield on the hedged slice.
- If stake APY rises → PT lags vs. the loop, but the unhedged 85 % of the
  loop captures the upside.

Net: variance compressed at modest expected-yield cost.

## Sizing the hedge slice (15 %)
- Loop pays `L × (stake_apr − borrow_apr)` on `(1 − h)` of borrowed BNB,
  where `h` is the hedge fraction.
- Hedge pays `pt_implied_rate − borrow_apr` on `h × leveraged_borrow`.
- For PT implied rate ≈ stake rate at entry and `h = 0.15`, the variance
  of total yield drops by ~30 % vs. unhedged, with only ~5 % expected
  yield reduction.

## Strategy steps
1. Start with 100 BNB.
2. For N=4 iterations:
   - BNB → slisBNB via Lista StakeManager.
   - Supply slisBNB to Venus vslisBNB.
   - Borrow BNB at 95 % of available liquidity.
   - **Carve 15 % of the borrowed BNB into PT-slisBNB** via
     `IPendleRouter.swapExactTokenForPt`.
   - Re-stake the remaining 85 % into Lista on the next iteration.
3. Hold 30 days. PT accrues toward par; loop accrues stake / borrow drift.
4. Re-mark slisBNB and PT to current rates and report PnL.

## PnL math (indicative)
- Loop yield (B01-01): +0.565 BNB / 100 BNB / 30 days at 4.0 % stake APY.
- Hedge slice (15 % × levered borrow ≈ 25 BNB notional): if PT implied
  yield = 4.2 % vs. unhedged 4.0 %, PT contributes ≈
  25 × (4.2 − 2.2) % × 30/365 = **+0.041 BNB** even in flat-rate scenario.
- Variance hedge value (rate compression scenario): if stake APY falls
  to 2.5 % over the hold, the unhedged loop nets ≈ +0.05 BNB instead of
  +0.56 BNB. The PT slice still pays +0.041 BNB. Net expected with
  20 % probability of compression: +0.41 BNB vs. unhedged +0.46 BNB —
  yield gives up 0.05 BNB to halve the downside.

## Block pinned
**42_000_000** — needs Venus slisBNB market *and* live Pendle PT-slisBNB
market. Re-pin once both are verified on-chain.

## Addresses used / TODOs
- `BSC.LISTA_STAKE_MANAGER`, `BSC.slisBNB`, `BSC.VENUS_COMPTROLLER`,
  `BSC.vBNB`, `BSC.PENDLE_ROUTER_V4` — from BSC.sol.
- `LOCAL_VSLISBNB` — Venus vslisBNB. **TODO verify** (same placeholder as
  B01-01).
- `LOCAL_PT_SLISBNB_MARKET` — Pendle market. **TODO verify** against
  Pendle BSC subgraph.

## Risks
- **Pendle BSC liquidity is thin**: 15 % hedge per iteration ≈ 3–6 BNB,
  well within typical PT pool depth; verify at FORK_BLOCK.
- **PT cannot be borrowed against (yet)**: hedge slice is *unlevered*, so
  it lowers leverage on the deployed capital — accounted for in the
  85 % re-stake split.
- **PT illiquidity at exit**: held to maturity removes this risk; for
  emergency exit Pendle's market may have 1–3 % slippage.

## Result
Status: **theoretical**. Expected: **+0.45–0.65 BNB / 100 BNB / 30 days**
with materially lower variance than pure B01-01.
