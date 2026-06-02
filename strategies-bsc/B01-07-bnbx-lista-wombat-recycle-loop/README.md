# B01-07: BNBx → Lista Lending → borrow WBNB → Wombat WBNB/BNBx recycle (3-mech)

## Mechanism — three BSC primitives stacked
1. **Stader BNBx**       — non-rebasing BNB LST. Mint via
   `IStaderStakeManager.deposit{value}()` at the internal `getExchangeRate`.
2. **Lista Lending**     — supply BNBx as collateral, borrow WBNB. Uses
   Lista's lending IRM (not Venus), diversifying borrow-cost dynamics.
3. **Wombat StableSwap** — instead of always re-minting through Stader
   each iteration, the borrowed WBNB is routed through the Wombat
   WBNB/BNBx dynamic-asset pool when the pool quote beats Stader's
   internal mint rate. Wombat's invariant favours under-weighted assets,
   so whenever the pool is short BNBx the swap delivers a **per-loop
   bonus** on top of the standard stake-rate carry.

This is the natural cross-protocol upgrade of B01-02: same collateral
asset (BNBx), different venue (Lista vs. Venus), different recycle path
(Wombat vs. Stader). The Wombat leg is **opt-in per iteration** —
governed by a min-edge check against the Stader rate.

## Why Wombat helps on the recycle
- Stader's mint is an internal accounting move: `bnbx_out = bnb_in /
  exchangeRate`. Zero slippage, but also zero edge: minting at the same
  rate every loop captures only the stake APY.
- Wombat's BNBx/WBNB pool runs on dynamic asset weights. When farmers
  unwind BNBx-side liquidity (e.g. after a Wombat MasterWombat-V3 reward
  rotation, or a large MEV unwind), the pool runs short BNBx and quotes
  **above-internal-rate** for WBNB → BNBx swaps. Empirically the
  Wombat-vs-Stader edge sits in the 5–30 bps range during normal markets
  and can spike to 100+ bps for ~hours after big unwinds.
- The strategy gates on `WOMBAT_MIN_EDGE_BPS = 5`: take Wombat only when
  the quote pays at least 5 bps more BNBx than Stader. Below that, the
  swap haircut + slippage eats the edge, so fall back to Stader mint.

## Strategy steps
1. Start with 100 BNB. Cold-start: mint full principal into BNBx via
   Stader (no Wombat liquidity dependency on entry) and supply to Lista
   Lending.
2. For N=4 iterations:
   - `lending.borrow(WBNB)` at 95 % of available.
   - Compare Stader's `getExchangeRate` to Wombat's
     `quotePotentialSwap(WBNB, BNBx)` for the borrowed amount.
   - Take Wombat path if `wombat_out ≥ stader_out × (1 + 5bps)`;
     otherwise unwrap WBNB → BNB and mint via Stader.
   - Supply resulting BNBx back to Lista.
3. Hold 30 days. Loop captures BNBx stake APY × Lista debt APR spread
   *plus* sum of per-iteration Wombat skew edges.
4. Re-mark BNBx oracle to Stader rate (Wombat skew converges over the
   hold) and report PnL.

## PnL math (indicative)
- Base loop carry (B01-02 analog): `+0.45–0.55 BNB / 100 BNB / 30 days`
  at BNBx stake APY ≈ 4.1 %, Lista WBNB borrow APR ≈ 2.5 %.
- Wombat skew capture: 4 iterations × average 10 bps edge × levered
  borrow (~150 BNB cumulative recycled) ≈ **+0.06 BNB extra**.
- Total: **+0.5–0.6 BNB / 100 BNB / 30 days**.
- Gas: ~1.8M gas (extra Wombat quote + swap per iteration). $1.10 at 1
  gwei × $600/BNB.

## Block pinned
**41_500_000**. Needs:
- Lista Lending BNBx market live.
- Wombat WBNB/BNBx pool deployed and seeded.

## Addresses used / TODOs
- `BSC.WBNB`, `BSC.LISTA_STAKE_MANAGER` not needed; we go via Stader,
  not Lista stake.
- `LOCAL_STADER_STAKE_MANAGER`, `LOCAL_BNBX` — same placeholders as B01-02.
- `LOCAL_LISTA_LENDING` — Lista Lending pool. **TODO verify**.
- `LOCAL_WOMBAT_BNBX_POOL` — Wombat WBNB/BNBx dynamic pool. **TODO
  verify** against the Wombat BSC pool registry; placeholder is a
  documented Wombat-family contract address pattern.

## Risks
- **Wombat asset cap**: dynamic-asset pools have per-side caps; large
  recycle iterations may exceed cap and revert. Mitigation: try/catch
  the quote, fall back to Stader if quote=0.
- **Wombat haircut growth**: as the loop grows, each subsequent Wombat
  swap is bigger, pushing the BNBx-side weight further toward
  oversupply. The 10 bps slippage tolerance keeps execution but reduces
  edge. The min-edge gate self-disables Wombat once the skew is
  exhausted.
- **Lista Lending HF**: same as B01-03; HF must stay > 1.05. The
  SAFETY_BPS=95 % keeps a 5 % buffer.
- **Stader pause / rate change**: identical to B01-02.

## Result
Status: **theoretical**. Expected: **+0.5–0.6 BNB per 100 BNB / 30 days**
— a 5–15 % uplift over B01-02 from the Wombat skew capture, at the cost
of one extra cross-protocol approval per iteration.
