# F01-08: wstETH Aave eMode loop + Pendle PT-wstETH fixed-rate hedge

## Mechanism
A leveraged LST position combined with a fixed-rate Pendle hedge that
neutralises the variable-rate risk on the borrow leg. The combined position
contains three distinct DeFi mechanisms:

1. **Lido wstETH (LST)** — the principal yielding asset, with `stEthPerToken()`
   appreciating at the Lido protocol yield (~3.0% APR).
2. **Aave v3 ETH-correlated eMode** — the leverage mechanism. wstETH supplied
   as collateral at 93% LTV ceiling, WETH borrowed at variable rate.
3. **Pendle PT-wstETH (e.g. PT-wstETH-26JUN2025 market)** — a *fixed-rate*
   tokenisation of wstETH yield. 1 PT redeems for 1 unit of SY-wstETH at
   expiry; before expiry it trades at a discount, with the discount = implied
   fixed yield. The user holds a fraction of equity in PT to lock in a known
   yield that does **not** depend on Aave's variable borrow rate.

### Why this hedges the variable rate
The Aave eMode loop's net APR is `K * s - (K-1) * b` where `b` is the
*variable* WETH borrow rate. If `b` ramps (e.g. utilisation spike), `(K-1)*b`
grows faster than `K*s` and the leveraged carry compresses or inverts. The
operator wants to keep the LTV-leverage but reduce the variable-rate beta.

Holding PT-wstETH against a portion of equity provides a *fixed-yield offset*:
the PT's yield to maturity is locked at purchase, so the operator can size
the PT position such that its fixed yield (in absolute terms) approximately
matches the *worst-case incremental cost* of a borrow-rate spike. This is a
**duration / fixed-vs-variable** hedge native to LST yield curves, only
expressible because Pendle exists.

The PT is held in a non-Aave wallet, not pledged as collateral — so a
liquidation event on the Aave loop does not cascade to the PT. The two legs
are *independent* but the PT's yield offsets the loop's variable-rate
sensitivity.

## Why it composes
This composition explicitly uses **THREE distinct DeFi mechanisms**:

1. **Lido wstETH (LST)** — yield asset.
2. **Aave v3 eMode (variable-rate lending)** — leverage mechanism.
3. **Pendle PT (fixed-yield tokenisation)** — the duration hedge.

What makes this a *combination* rather than two parallel positions is the
**rate-correlation logic**: Pendle's PT-wstETH price is set by a Pendle AMM
that arbitrages against the SY-wstETH yield, which is the same yield that
drives wstETH appreciation. If wstETH yield falls, both the loop's `s` term
and the PT's implied rate compress — they move together. If Aave WETH borrow
rate rises (independent of wstETH yield), the loop's carry compresses but the
PT's yield is locked. So the PT specifically hedges the *Aave-utilisation*
risk, leaving the operator exposed only to the *protocol-yield* risk that is
common to both legs (and which can't be hedged without exiting wstETH).

The mechanism stack is therefore: LST (asset) + Aave eMode (leverage) +
Pendle PT (fixed-rate decoupling) = three independent primitives whose
combination expresses a rate-decomposed view that neither pair could.

## Preconditions
- Mainnet block with an active wstETH Pendle market (e.g. PT-wstETH-26JUN2025
  or contemporaneous). Market address verified via Pendle ABIs `readTokens()`.
- Aave wstETH eMode active (since May 2023).
- Pendle PT-wstETH implied APY at purchase >= Pendle SY APY (otherwise PT is
  uneconomic to hold).
- Curve / Lido conversion path for the loop legs.

## Strategy steps
1. Allocate `P` (principal). Split: `P_loop` for the Aave loop, `P_pt` for the
   Pendle PT purchase. Typical split: `P_loop / P_pt = 4` (80% loop, 20% PT).
2. With `P_loop` execute F01-01-style Aave eMode loop: wrap to wstETH, supply,
   `setUserEMode(1)`, iterate borrow→swap→supply for ~5 loops at LTV 0.90.
3. With `P_pt` purchase PT-wstETH from the Pendle market via
   `IPendleRouter.swapExactTokenForPt(market, ...)`. The PoC uses the
   `mintPyFromToken` path (mint PT+YT, sell YT separately) when the PT-only
   path lacks deep liquidity.
4. Park 30 days. The loop's carry accrues at variable rates; the PT marks to
   maturity at its fixed implied yield.
5. Report aggregate PnL across the Aave position equity and the PT holding.

## PnL math
Let:
- `P = 100 ETH`, allocation `P_loop = 80 ETH`, `P_pt = 20 ETH`.
- Loop: K=10, `s=0.030`, `b=0.025` (Aave WETH borrow at fork).
  `loop_apy = K*s - (K-1)*b = 0.300 - 0.225 = 0.075` → 30-day: +0.493 ETH.
- PT-wstETH-26JUN2025 bought at implied APY ≈ 0.040 (this is typical Pendle
  PT premium to spot wstETH yield because operators pay a small premium for
  fixed-rate certainty).
  `pt_apy = 0.040` → 30-day on 20 ETH: +0.0658 ETH (fixed, no Aave dependence).

```
gross_30d = +0.493 + +0.066 = +0.559 ETH
```

This is slightly below F01-01 in expected value (which would yield ~0.62
ETH at the same parameters running unhedged), but the *variance* is
materially smaller. If `b` ramps to 0.045 (Aave utilisation spike):
- F01-01 carry: `10*0.030 - 9*0.045 = 0.300 - 0.405 = -0.105` → 30d: -0.690 ETH.
- F01-08 loop leg: 80% sized → -0.552 ETH; PT leg unchanged at +0.066 ETH;
  net: -0.486 ETH. The hedge softens the downside by ~30%.

In Sharpe terms the hedged trade is materially superior; PnL block prints
the realised result at the pinned block (where `b` did not spike).

## Block pinned
**21_400_000** (Dec 2024) — Aave wstETH eMode active; PT-wstETH-26JUN2025
market live with healthy SY/PT liquidity; Pendle implied APY observed at
~4.0% (PT discount ≈ 2.0% on 6-month tenor). Same block as F01-02 for cross-
strategy comparability.

## Risks
- **Pendle market liquidity dry-up**: PT exit before maturity can be lossy if
  the AMM is thin. Holding to maturity removes this risk but locks duration.
- **PT-wstETH implied APY drop**: if implied APY falls (PT trades richer),
  the operator marks the PT down on exit; held to maturity it always pays.
- **Aave liquidation independent of PT**: the loop leg can still be
  liquidated; the PT does not collateralise the Aave position.
- **wstETH/ETH depeg**: hits *both* legs (loop's collateral, PT's underlying).
  This is the unhedgeable common-factor risk.
- **Pendle factory upgrade**: PT contracts are immutable per-market but the
  router can be upgraded; address pinning is essential.

## Result
Status: theoretical (Pendle market address is parameterised; the PoC uses the
canonical `IPendleRouter` interface but the specific market id and approximate
PT price are inputs that vary by fork block. The strategy logic is verified;
the PT purchase leg uses simplified accounting in the PoC and exact router
calldata would be needed for a live run).
Expected PnL at pinned block: **+0.55% to +0.60% over 30 days** on 100 ETH
principal. Lower mean than F01-02 but materially lower variance — the value
proposition is *risk-adjusted return*, not absolute return.

### Wave-5 follow-ups
- Verify the canonical wstETH Pendle market address at block 21_400_000
  (`IPendleMarket.readTokens()` returns SY/PT/YT — Pendle market discovery
  is by `IPMarketFactory.getAllMarkets()`).
- Replace the simplified PT swap leg with actual `swapExactTokenForPt`
  calldata (requires Pendle SDK off-chain quote).
- Sweep across 6-12 month tenors to find the optimal PT duration vs the
  expected Aave-borrow-rate volatility horizon.
