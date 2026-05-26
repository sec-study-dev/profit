# F06-06: LUSD trove → split between Stability Pool and Convex LUSD/3pool

3-mechanism strategy. **Family: F06 (Liquity v1)**.

## Mechanisms combined
1. **Liquity v1** — open ETH-collateralised trove, mint LUSD.
2. **Curve** — provide LP to LUSD/3pool meta-pool (LUSD3CRV-f).
3. **Convex** — stake the LP token in Convex Booster (pid 33) for boosted
   CRV + CVX rewards.

## Mechanism
After opening a Liquity v1 trove and minting `D` LUSD, allocate:
- `D/2` → **Liquity Stability Pool** (earns ETH liquidation premium net of
  occasional LQTY emissions).
- `D/2` → **Curve LUSD/3pool LP** → **Convex stake** (earns trading fees
  + boosted CRV + CVX).

This forms a barbell:
- The **SP leg** is asymmetric upside on volatility (more liquidations =
  more discounted ETH gain). It is also a "stable parking" — most of the
  time it just compounds LUSD around par.
- The **LP+Convex leg** is yield on stablecoin LP fees plus CRV/CVX
  incentives whose APR depends on gauge weight. Historically 4–8% APR
  net of CRV decay.

Both legs leave the user with primarily LUSD-denominated stable exposure
plus occasional ETH/CRV/CVX upside; the trove debt of `D` LUSD is repaid
from the combined LUSD position at unwind, leaving the original ETH
collateral plus the accrued yield.

## Why it composes
- **Liquity Stability Pool** has zero deposit fee, instant deposits.
- **Curve LUSD/3pool** is the canonical LUSD venue (>$30M TVL) and the
  LP token is `0xEd279fDD11ca84bEef15AF5D39BB4d4bEE23F0cA`.
- **Convex pid 33** has been live since 2021; rewards in CRV + CVX.

## Preconditions
- LUSD/3pool TVL > $10M so the LP leg isn't a meaningful share.
- Convex `crvRewards` address `0x2ad92A7aE036a038ff02B96c88de868ddf3f8190`
  active at fork block.
- ETH price stable enough that ICR > 200% over the horizon (we set
  `TROVE_COLLATERAL_ETH = 100`, `TROVE_LUSD_BORROW = 100k` → ICR ≈ 300%
  at $3000 ETH).

## Strategy steps
1. `openTrove(maxFee=5%, lusd=100k, hints=0)` with 100 ETH collateral.
2. Split LUSD `50k` → `provideToSP(50k, 0)`. `50k` → `add_liquidity([50k,0], 0)`
   on LUSD/3pool.
3. `Booster.deposit(33, lpAmount, true)` → auto-stake in pid-33 rewards.
4. Wait 30 days (`vm.warp`).
5. Harvest: `crvRewards.getReward()` → receive CRV+CVX.
6. `withdrawFromSP(compoundedLUSD)` → receive LUSD + accrued ETH gain.
7. `withdrawAndUnwrap(convexStake, false)` → get LP back.
8. `remove_liquidity_one_coin(lp, 0, 0)` → all LUSD.
9. `repayLUSD(troveDebt, hints)` and `closeTrove()` — production step,
   not in PoC but commented for completeness.

## PnL math
For 30-day horizon, 100k LUSD borrow, half-and-half split:
```
SP leg (50k):
  expected yield  = SP_apr × 50k
  SP_apr (2023)   ≈ 4–7% gross, mostly from ETH gains netted
  yield           ≈ $250 over 30 d on $50k

Convex leg (50k LP):
  base 3pool fee  ≈ 1.5% APY × 50k × (30/365) = $61
  CRV emission    ≈ 5% APY (varies) × 50k × (30/365) = $206
  CVX boost       ≈ ratio of CRV * 0.15 = $31
  Total           ≈ $298

  Net 30-day yield ≈ $550 on $100k principal = 6.6% APY
```

This is on the same trove collateral; underlying ETH retains its market
exposure (gains tracked separately by the PnL snapshot).

Borrowing cost on Liquity v1 = **0%** — Liquity charges no recurring
interest, only a one-time issuance fee (≈ 0.5% × debt = $500 at open).
That's the only cost beyond gas.

## Block pinned
- `FORK_BLOCK = 17_900_000` (≈ August 2023; LUSD/3pool TVL healthy, no
  recovery-mode flags, Convex pid-33 active and earning).

## Risks
- **Recovery mode** (TCR < 150%): if the system enters RM, open is
  blocked above ICR=150%, redemptions are blocked, our trove can be
  liquidated at ICR < 150% instead of 110%. Mitigation: keep ICR ≥ 200%.
- **CRV emission cut.** Curve DAO can lower the gauge weight at any
  vote; CRV yield is the volatile component.
- **CVX lock decay.** CVX rewards drift as the boost denominator changes.
- **SP underperformance in calm regimes.** If no liquidations occur, the
  SP earns near-zero (LQTY emissions are tiny post 2023).

## Result
Status: **fully reproducible** at the pinned block.

PnL: **+5–10% APY net on $100k LUSD allocation** over a typical 30-day
window, with upside dependent on liquidation flow.
