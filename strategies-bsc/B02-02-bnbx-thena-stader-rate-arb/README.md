# B02-02: BNBx / WBNB Thena ve(3,3) vs Stader internal rate arb

## Mechanism
Stader's BNBx is a non-rebasing BNB LST whose canonical rate is exposed via
`IBNBx.getExchangeRate()` (1e18-scaled BNB per BNBx). The dominant non-PCS
venue for BNBx is **Thena**, a Solidly/Velodrome ve(3,3) fork. Thena's
"stable" pair invariant (`x^3*y + y^3*x = k`) keeps quotes close to peg but
not at it — and because Thena's emissions schedule moves veTHE-weighted
liquidity around weekly, the BNBx/WBNB Thena pair routinely diverges
10-40 bp from Stader's internal exchange rate.

The arb:

1. PCS v3 single-pool `flash(WBNB)` from a deep WBNB/USDT (or WBNB/BUSD) pool
   to source notional cheaply.
2. Swap flashed WBNB -> BNBx via Thena's stable pair using
   `IThenaRouter.swapExactTokensForTokens` with `stable=true`.
3. Read `bnbXValueInBnb = bnbXOut * IBNBx.getExchangeRate() / 1e18`.
4. If `bnbXValueInBnb > flashWbnb + flashFee`, the trade is profitable.
5. Two exit paths:
   - **Atomic**: route BNBx -> WBNB back via the **PCS v3** BNBx/WBNB pool
     (different venue) to close the loop in one tx, capturing the inter-DEX
     spread directly.
   - **Queue (modelled)**: `IBNBxStakeManager.requestWithdraw` on Stader and
     receive 1:1-at-internal-rate after the cooldown. PoC values BNBx
     retained at `getExchangeRate()` via an oracle override.

PoC implements the **atomic close** path with the PCS v3 leg as the exit.
The dislocation we exploit is *Thena BNBx/WBNB stable quote* vs
*PCS v3 BNBx/WBNB quote*, both anchored by — but free to drift around —
Stader's `getExchangeRate()`.

## Why it composes
- **PCS v3 flash**: same low-cost atomic funding leg as B02-01.
- **Thena stable pair**: solidly stable curve has *different* slippage shape
  than v3 CL pools at small sizes; for BNBx/WBNB the stable curve often
  shows BNBx cheaper because of one-sided LP rotation around veTHE epochs.
- **Stader internal rate as oracle**: `getExchangeRate()` is the "truth"
  rail; both legs of the arb tend to mean-revert to it after a few blocks.

## Preconditions
- Thena BNBx/WBNB **stable** pair exists. Address discovered via
  `IThenaRouter.pairFor(BNBx, WBNB, true)`. **TODO verify** the pair has
  meaningful TVL (> 500 WBNB equivalent) at the chosen block.
- PCS v3 BNBx/WBNB pool exists at 0.05% or 0.25% fee tier. **TODO verify**.
- Stader exchange rate is fresh (it's pushed by the Stader operator on
  every reward distribution; expect stale-by-up-to-24h windows).

## Strategy steps
1. Flash WBNB from a deep PCS v3 WBNB pool (use WBNB/USDT 0.05% tier
   `0x36696169C63e42cd08ce11f5deeBbCeBae652050` — TODO verify).
2. In callback, leg A: swap WBNB -> BNBx on Thena stable pair via the router.
3. Read `bnbX = balance`, `rate = IBNBx.getExchangeRate()`.
4. Leg B (atomic close): swap BNBx -> WBNB on PCS v3 (the *other* venue).
   The intermediate "free" BNB amount is what the strategy captures.
5. Repay flash + fee to the original flash pool.
6. Any residual WBNB in the strategy after repayment is the arb profit.

## PnL math
Let `T = Thena quote` (BNBx per WBNB), `V = PCS v3 quote` (WBNB per BNBx).
For flash notional `N` WBNB:

- BNBx out from Thena: `N * T`
- WBNB out from PCS v3: `N * T * V`
- Gross PnL (WBNB): `N * (T * V - 1)`
- Flash fee (5 bp on the source pool): `N * 0.0005`

If Thena gives BNBx 30 bp cheaper than fair (`T = (1/R) * 1.003`) and
PCS v3 prices BNBx at fair (`V = R`), then `T * V = 1.003` and
gross = 0.003 * N. For `N = 1000 WBNB` → 3 WBNB ≈ $1,800.

Realistic spreads (BNBx is thinner than slisBNB):
- Quiet: 8-15 bp → $480-900 per 1000 WBNB
- Stress (BNBx sell-off, Stader epoch boundary): 30-60 bp → $1,800-3,600

## Block pinned
- `FORK_BLOCK = 45_000_000` (placeholder). **TODO** pin a block where
  Thena stable BNBx/WBNB shows ≥20 bp BNBx discount vs PCS v3 spot.

## Risks
- **Thena stable curve depth**: BNBx/WBNB stable pair TVL is much smaller
  than slisBNB/WBNB; >300 WBNB sizes may eat most of the spread to slippage.
- **Solidly invariant edge cases**: at extreme imbalance the stable
  `x^3*y + y^3*x = k` curve can over- or under-quote vs the constant-product
  approximation, but Thena's `getAmountOut` already handles this.
- **Stader rate staleness**: if `getExchangeRate()` was last poked many hours
  ago, the "internal rate" may briefly lag actual yield accrued. This *helps*
  the arb (the DEX has already priced in the new rate) but reduces the
  signal value of the comparison.
- **Pair direction**: Thena's `pairFor(tokenA, tokenB, stable)` sorts
  tokens; the PoC re-derives token order via the pair's `token0/token1`
  view.

## Result
- Status: **theoretical / offline-first**.
- Expected PnL: **+$400 to +$3,000 per 1000 WBNB** depending on Thena epoch.
