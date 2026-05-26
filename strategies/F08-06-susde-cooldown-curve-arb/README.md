# F08-06: sUSDe cooldown vs Curve discount arbitrage (2-mech)

## Mechanism

Ethena's sUSDe ERC-4626 wrapper has two exit paths:

1. **Cooldown queue**: `cooldownShares(shares)` locks the shares, the
   user receives a *promise* of `convertToAssets(shares)` USDe payable
   after `cooldownDuration` seconds (7 days at activation; protocol can
   set it via `setCooldownDuration`). Then `unstake(receiver)` releases
   the underlying USDe at full NAV.
2. **Secondary AMM**: sell sUSDe immediately on a Curve sUSDe/USDe
   factory pool (or PT-sUSDe/SY-sUSDe Pendle AMM), getting the spot
   price minus AMM fees.

These two exit prices diverge during redemption surges:

- A withdrawal panic causes secondary-market sellers to dump sUSDe on
  Curve, pushing the spot price below NAV by 30-200 bps.
- The cooldown queue still pays full NAV — but requires a 7-day wait
  and forfeits sUSDe yield accrual during the wait.

When `secondary_discount_bps > 7-day yield-foregone bps`, the arb is:

```
1. Buy sUSDe on the discount-side Curve pool.
2. cooldownShares(allShares) — locks 7d, schedules NAV-USDe release.
3. wait 7 days.
4. unstake() — claim NAV-USDe, sell on Curve USDe/USDC for clean USDC.
```

Realised PnL = `(NAV - spot_purchase_price) - 7d_yield_foregone -
2 × Curve fee`.

## Why it composes

Two protocol primitives:

1. **Ethena sUSDe cooldown queue** — the *guaranteed-NAV exit*. It is
   the only mechanism that pays full underlying USDe regardless of
   secondary-market quotes. The 7-day duration is the cost paid in
   exchange for that guarantee.
2. **Curve secondary AMM** — the *immediate-liquidity exit*. Spot
   prices reflect short-term supply/demand and detach from NAV in
   stress. The pool the arber uses depends on what is depegged at the
   moment (sUSDe/USDe pool, USDe/USDC pool, or the 4-coin pool).

The composition is asymmetric: the long-side (cooldown) is robust to
peg variance; the short-side (Curve sell at NAV after 7d) is just a
peg-tolerant stable swap (USDe→USDC). The strategy converts
secondary-market panic into a 7-day duration trade.

## Preconditions

- Mainnet fork at a block where Ethena's sUSDe cooldown is enabled
  (`cooldownDuration > 0`). Block `20_800_000` (Sep 2024) satisfies
  this; cooldown was activated 2024-04-01 and remains enabled.
- A measurable secondary discount on sUSDe vs NAV. The PoC at the
  pinned block may show zero discount (peg-converged); in that case
  the realised PnL = (sUSDe NAV accrual over 7 days) − Curve fee,
  which is approximately the floor of the arb (just the carry on the
  underlying staked position over the cooldown window).
- Curve USDe/USDC depth > 1M USDC for the entry-leg swap.

## Strategy steps

1. `_fund(USDC, this, 1M)`.
2. Curve USDC → USDe (1M USDC notional, < 5 bps slippage at 1M scale).
3. `sUSDe.deposit(usde, this)` → `shares = convertToShares(usde)`.
4. `sUSDe.cooldownShares(shares)` → schedules `cooldownDuration`-later
   release of `convertToAssets(shares)` USDe.
5. `vm.warp(now + cooldownDuration + 1)`.
6. `sUSDe.unstake(this)` → claims `usde_claimed`.
7. Log `(claimed - 1M USDC * 1e12)` as the PnL in USDe units.

## PnL math

Two regimes:

### Regime A — No secondary discount (peg-converged)

`pnl = NAV_growth_over_7d − curve_entry_fee_4bps`

At ~14% sUSDe APY, 7-day growth = `0.14 * 7 / 365 ≈ 0.269%`. Minus
Curve fee 4 bps = **~+22 bps net = ~$2.2k on 1M notional**.

### Regime B — 50 bps secondary discount on sUSDe

`pnl = 50bps_discount + 7d_yield − 4bps_curve_entry − 4bps_curve_exit`
     = `50 + 27 − 4 − 4 = 69 bps net ≈ $6.9k on 1M notional`.

### Regime C — depeg sale at 200 bps (Aug 2024-style)

`pnl ≈ 200 + 27 − 8 ≈ 219 bps net ≈ $21.9k on 1M notional`.

The strategy size-bounded by the **depth of the discount-side Curve
pool**. The sUSDe/USDe pool (factory) has been ~$30M at deep blocks;
above 5M notional the discount collapses inside the swap.

## Block pinned

**20_800_000** (~Sep 24 2024). At this block sUSDe cooldown is enabled
and the secondary peg has historically been within 30 bps. The PoC
therefore typically realises a ~+25-50 bps run (Regime A or shallow B).

## Risks

- **NAV clawback / fee turn-on**: Ethena governance can introduce a
  unstake fee on the cooldown path. PoC assumes zero fee.
- **Cooldown extension**: governance can raise cooldownDuration. A
  jump from 7d → 14d doubles the carry-lost duration and reduces the
  arb's edge proportionally.
- **USDe depeg during the 7d wait**: between cooldownShares and
  unstake, USDe peg risk is borne by the holder. A depeg event during
  the wait reduces the claimable USD value.
- **Reorg / fork**: 7-day duration is a long time-frame for L1 risk
  to materialise (e.g. a 51% attack, validator exit queue stall).
  Mainnet has not had a reorg > 12 blocks in years; risk is low but
  not zero.
- **Cooldown queue front-running**: an L2 / off-chain co-ordinated
  panic could fill the cooldown queue beyond Ethena's funding
  capacity. Ethena would then pay out from reserves; if reserves are
  exhausted, redemption is delayed beyond the nominal 7-day window.

## Result

Status: theoretical. Forge build not run. On the pinned block expected
realised PnL is dominated by the 7-day sUSDe yield accrual term
(~+22-30 bps net of fees). A measurable secondary-market discount at
entry adds linearly to that floor — the strategy is *additive* against
sUSDe's underlying carry, not in competition with it.
