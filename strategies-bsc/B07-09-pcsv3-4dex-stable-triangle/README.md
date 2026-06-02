# B07-09: PCS v3 USDC flash + 4-DEX stable triangle (v2 / v3 / Wombat / Thena stable)

## Mechanism (3-mech)
Four BSC stable venues, each with a **different invariant**, route the
same USDC↔USDT trade differently. Among them we form a flash-funded
two-hop cycle (the flash venue + 2 swap legs across 2 distinct other
venues), giving 3 actively-used mechanisms per fire:

1. **PancakeSwap v2 USDT/USDC pair** — x·y = k, 0.25% fee. Used as
   the high-fee, retail-priced leg.
2. **PancakeSwap v3 USDT/USDC 0.01% pool** — concentrated-liquidity
   stable band, also our flash source.
3. **Wombat Main Pool** — dynamic-asset-weight StableSwap; the
   haircut on a USDC→USDT swap depends on USDC and USDT coverage
   ratios separately. Often the *favourable* leg.
4. **Thena USDT/USDC STABLE pair** — Solidly stable invariant
   `k = x³y + xy³`, 0.04% fee. Bribe-driven LPs leave it stale.

Per fire the strategy enumerates three curated cycles (each touching
exactly two of {v2, Wombat, Thena stable} for the swap legs, plus the
v3 flash), picks the best USDC-out, and fires if net of the flash
fee beats `MIN_NET_EDGE_BPS`.

## Why it composes
- **Three different stable invariants per swap leg** means three
  independent re-pricing schedules. v2 LPs don't watch v3, Wombat LPs
  watch coverage not price, Thena LPs watch THE bribes. Re-syncs
  happen on different clocks — small cross-venue drifts are
  persistent.
- **Cycle selection on-chain.** With 24 cycles (4·3·2) we can route
  to whichever pair is best; the PoC samples three representative
  cycles to keep gas bounded.
- **Same-asset round-trip = no inventory risk.** USDC → USDT → USDC
  starts and ends in USDC; no overnight exposure.

## Preconditions
- All four venue pools live and unpaused at the fork block.
- PCS v3 USDC/USDT 0.01% has ≥ 1M USDC active-tick liquidity.
- Sum of swap fees on the chosen cycle + 1 bp flash + slip ≤ available
  spread.

## Strategy steps
1. Quote each of three cycles (Wombat→Thena stable, Thena stable→
   Wombat, v2→Wombat) at FLASH_NOTIONAL_USDC = 1M.
2. Pick `bestOut = max(cycle_outs)`. If `bestOut < notional + 1bp +
   MIN_NET_EDGE_BPS`, skip.
3. Flash USDC from PCS v3 0.01% pool.
4. Callback dispatch on `Cycle` enum:
   - Run leg 1 (USDC → USDT on selected venue A).
   - Run leg 2 (USDT → USDC on selected venue B).
   - Transfer `notional + flashFee` USDC to repay.

## PnL math
1M USDC notional. Suppose Wombat is over-paying USDT (USDC over-
covered, 12 bps subsidy) and Thena stable is at par with 4 bp fee:
- Wombat USDC→USDT: 1M × (1 + 12/10_000) − 4 bp haircut ≈ 1_000_800.
- Thena stable USDT→USDC: 1_000_800 × (1 − 4/10_000) ≈ 1_000_400.
- PCS v3 flash fee: 100 USDC.
- **Net: 1_000_400 − 1_000_100 = +$300 per fire.**

At an 18 bp Wombat skew + 5 bp Thena drift the same cycle yields
**+$700–1_200**. v2-leg cycles fire less often (0.25% fee dominates)
but occasionally catch outsized retail flow at 30+ bps net.

Hit rate: ~3–8 fires/day on the Wombat-favoured cycles; ~0.5/day on
v2-leg.

## Block pinned
**42_000_000** — sentinel. Wave 3: pin to a block right after a large
single-token Wombat deposit (coverage skew event).

## Addresses used
- `0x92b7807bF19b7DDdf89b706143896d05228f3121` — PCS v3 0.01% USDT/USDC.
- `BSC.WOMBAT_MAIN_POOL` — Wombat dynamic StableSwap.
- `0x6321B57b6fdc14924be480c54e93294617E672aB` — Thena USDT/USDC stable
  pair. **Placeholder** — Wave 3 verify via `Router.pairFor(USDT,
  USDC, true)`.
- `0xEc6557348085Aa57C72514D67070dC863C0a5A8c` — PCS v2 USDT/USDC pair.
  **Placeholder** — derive via PCS_V2_FACTORY.
- `BSC.PCS_V3_ROUTER`, `BSC.PCS_V2_ROUTER`, `BSC.THENA_ROUTER`.

## Risks
- **Pool inactivity** — any of the four pools paused at fork block
  causes the quote leg to return 0; PoC then picks a different cycle
  or skips.
- **Wombat coverage flip mid-tx** — large flash shifts USDC/USDT
  coverages enough to invert the haircut; PoC's slippage-min = 1 is
  unsafe in prod. Wave 3 must bound notional to ≤ 1% of Wombat
  cash side.
- **v2-leg sandwiching** — PCS v2 USDT/USDC pair is shallow (~$2–5M)
  and any flash leg into it is sandwich-able. The v2 cycle should
  only be used when the other two cycles are both worse.
- **MEV** — 4-DEX stable triangles are exotic enough that ~3 known
  searchers cover them; single-shot capture ≈ 40–60%.

## Result
Status: **theoretical**. Expected PnL: **+$200–800 per fire on
Wombat-skew cycles; +$300–1_500 on rare large-skew events**. Strategy
is a deep-routing witness for B07-04's stable-arb family.
