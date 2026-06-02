# B14-03: lisUSD as savings wrapper — Lista Lending recursive carry

## Mechanism
Frame **lisUSD** as a *yield-bearing wrapper* — not just an overcollateralised
stable. Lista DAO routes part of its CDP fees and PSM surplus into a
**lisUSD savings program** that pays holders a continuously accruing
APR (mechanism analogous to MakerDAO's DSR but on BSC). When supplied
as collateral into Lista Lending, lisUSD continues to accrue the savings
rate *and* earns Lista-side supply APR — a stacked-yield wrapper.

This PoC builds a recursive loop entirely **within Lista's own venue**:

1. Supply lisUSD into Lista Lending (the supply leg earns both the
   lisUSD savings rate and the protocol supply APR).
2. Borrow USDT against the lisUSD collateral.
3. Swap USDT → lisUSD on Wombat (where Lista routes its main PSM-style
   liquidity; the StableSwap pool sits in lisUSD-coverage neutral state).
4. Re-supply lisUSD. Repeat.

Distinct from `B05-03` (which treats sUSDe as the wrapper and Lista as
the borrow venue) and from `B03-*` (which trades the lisUSD CDP /
redemption peg arb). Here the *collateral itself* is the yield primitive
and the loop scales its inherent rate.

## Why it composes
- lisUSD's savings program is **always-on** for holders and aggregated
  across both wallet and lending-protocol-supplied balances (Lista
  Lending honours the savings stream because supply is escrowed by Lista
  itself — there's no external venue stripping the yield).
- Lista Lending CF for lisUSD-supply against USDT-borrow is conservative
  but tight (~0.85) because both are USD-stable; the LTV cap is set by
  the redemption discount, not price volatility.
- Wombat's lisUSD pool is the canonical AMM exit, with Lista DAO seeded
  liquidity (~$15M at typical depth) and dynamic asset weights that
  rebalance against the redemption peg.

## Preconditions
- BSC block where Lista Lending's lisUSD market is live with active
  supply incentives + lisUSD savings APR ≥ 4 %.
- Wombat lisUSD/USDT pool USDT-side coverage ≥ 0.95 so the USDT → lisUSD
  swap clears at < 25 bp of slippage.
- USDT borrow APR on Lista Lending below `(lisUSD savings rate +
  lisUSD supply APR)` so the loop is positive-carry pre-leverage.

## Strategy steps (4 iterations, 100k lisUSD principal)
1. `_fund` 100k lisUSD into the test contract.
2. For `i = 0..3`:
   - `ListaLending.supply(lisUSD, balance, address(this))`.
   - `ListaLending.borrow(USDT, lisUSD_supplied * 0.85 * 0.95,
     address(this))`.
   - Wombat `swap(USDT → lisUSD, minOut = 99.7%)`.
3. Hold 30 days, force interest accrual via `getUserAccountData`.
4. PnL = `Δ lisUSD value − Δ USDT debt + Lista supply rewards − gas`.

Effective leverage at LTV 0.808 per step, N=4:
`L = 1 + 0.808 + 0.652 + 0.527 + 0.426 ≈ 3.41×`.

## PnL math (100k lisUSD principal, 30-day horizon)
Indicative rates at the pinned block:
- lisUSD savings rate (intrinsic wrapper yield): `4.0 %`.
- Lista Lending lisUSD supply APR: `2.5 %` (supply-side incentives).
- Lista Lending USDT borrow APR: `4.5 %`.
- Per-loop Wombat swap cost (USDT → lisUSD): `25 bp`.

Net supply leg: `4.0 + 2.5 = +6.5 %`.
Net borrow leg: `−4.5 %`.

Gross APY = `3.41 × 6.5 % + 2.41 × (−4.5 %) = 22.16 − 10.84 = +11.32 %`.
Swap drag = `25 bp × 2.41 leverage × 4 loops = 241 bp` (one-shot).

30-day PnL on 100k lisUSD:
- Carry term: `11.32 % × 30/365 × 100k ≈ +930 USD`.
- Swap drag: `−2.41 % × 100k = −2,410 USD`.
- Net 30-day PnL ≈ **−1,480 USD** ... *unless we hold longer*.

Break-even hold horizon = `swap_drag / monthly_carry = 2.41 % / (11.32 %
/ 12) = 2.55 months`. So **6-month hold** is the sensible production
horizon; 30-day PnL is shown for parity with sibling PoCs but the
strategy genuinely targets 90-180 day holds. Re-running the offline
projection at `HOLD_DAYS = 180`:
- Carry term: `11.32 % × 180/365 × 100k ≈ +5,580 USD`.
- Net 180-day PnL ≈ **+3,170 USD**.

Gas: 4 × (supply + borrow + Wombat swap) ≈ 3.0M gas × 1 gwei × $600/BNB
≈ `$1.8` — negligible.

## Block pinned
**42_500_000** (late-2024). Re-pin once Lista Lending lisUSD market is
verified active and savings-rate cadence is published on-chain. Strategy
is robust to ±500k block drift.

## Addresses used
- `0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5` — lisUSD (`BSC.lisUSD`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0xaA0F8c41E3DC22a8C4d4Da6da1A1cAF048D7e4b5` — Lista Lending
  (`BSC.LISTA_LENDING`).
- `0x19609B03C976CCA288fbDae5c21d4290e9a4aDD7` — Wombat Router
  (`BSC.WOMBAT_ROUTER`).
- `0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0` — Wombat main pool
  (`BSC.WOMBAT_MAIN_POOL`).

## Risks
- **Savings-rate cut**: Lista DAO governance can lower the savings APR
  if PSM surplus dries up. The strategy becomes unprofitable below
  `lisUSD savings + supply > USDT borrow`.
- **lisUSD redemption discount widens**: a structural ≥ 50 bp gap on
  the Wombat exit means each loop iteration loses non-trivial value.
  Cap per-iteration swap at $25k and abort the loop if slippage > 50 bp.
- **Lista Lending CF cut**: a step from 0.85 → 0.80 forces ~6 % unwind.
  Keep ≥ 5 % headroom above the new LTV.
- **Wombat pool coverage skew**: if USDT side over-covers (lisUSD
  drained), the inbound swap quotes lisUSD at a premium and the loop
  inverts. Monitor `WombatPool.assetCoverage(USDT)`.
- **Same-protocol concentration**: the entire position is intra-Lista —
  a Lista-side contract pause halts both legs simultaneously. Acceptable
  given the wrapper-internal nature of the carry.

## Result
Status: **theoretical** (BSC RPC not configured; PoC compiles and runs
the offline accounting branch). Expected PnL: **−1.5 % at 30d
(swap-cost-dominated) → +3.2 % at 180d (carry-dominated)** on 100k
lisUSD principal, sourced from stacking the lisUSD savings rate with
Lista's supply rewards against the borrow APR, amplified 3.4× by
recursive collateralisation.
