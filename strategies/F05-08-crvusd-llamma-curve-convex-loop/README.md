# F05-08: WETH/crvUSD LLAMMA → Curve crvUSD/USDC LP → Convex booster

## Mechanism

True three-mechanism composition: open a LLAMMA loan against WETH, deploy
the freshly-minted crvUSD as single-sided LP into the Curve crvUSD/USDC
stableswap-NG, then stake the LP token into Convex Booster to harvest
CRV + CVX emissions on top of the gauge.

1. **Curve crvUSD WETH-market LLAMMA borrow**
   - Controller: `0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635`
   - LLAMMA: `0x1681195C176239ac5E72d9aeBaCf5b2492E0C4ee`
2. **Curve crvUSD/USDC stableswap-NG LP**
   (`0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E`) — adds crvUSD only,
   captures swap fees + virtual_price drift.
3. **Convex Booster** (`Mainnet.CONVEX_BOOSTER` =
   `0xF403C135812408BFbE8713b5A23a04b3D48AAE31`) staked into PID 182's
   BaseRewardPool (`0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA`), which
   auto-claims the Curve gauge's CRV and mints CVX on a vesting cliff.

## Why it composes

Single-sided LP-add on a slightly off-peg stableswap mints fewer shares
than an even split — the pool "absorbs" the crvUSD into its imbalance.
This is intentional: when crvUSD is slightly under peg (very common
window during LLAMMA borrow-rate spikes), single-sided LP add is *long*
the recovery, *and* the Convex booster's gauge weight increases
proportionally. The strategy effectively *sells* crvUSD into the pool at
the moment it borrows it — a partial peg-hedge — while harvesting
Convex's CRV+CVX boost on the stake.

The three primitives are independent (each is a separate protocol on
mainnet) but only their *combination* produces a credit-risk-neutral
carry: removing Convex turns the strategy into a fee-only LP play (~3%
APR) which fails to clear LLAMMA's 6% borrow cost; removing the
crvUSD/USDC LP step turns the trade into a directional crvUSD short,
which loses on a peg-recovery rally.

## Preconditions

- WETH market has open debt ceiling (always at the fork block).
- Convex PID 182 is live (Booster.poolInfo(182).shutdown == false).
- Curve crvUSD/USDC gauge has positive emissions weight (it does at
  block 20_650_000; weight ~1.2%).

## Strategy steps

1. Verify Booster.poolInfo(182): `lptoken == CURVE_CRVUSD_USDC`,
   `crvRewards == 0x44D8FaB7...`.
2. Deposit 200 WETH as collateral; borrow 50% of max_borrowable in
   crvUSD.
3. `add_liquidity([crvUSDamt, 0], min_lp)` on Curve crvUSD/USDC. The
   pool's stableswap-NG implementation accepts asymmetric input and mints
   pool shares (the LP token == pool address).
4. Approve LP to Booster; `Booster.deposit(182, lpAmount, true)` — stakes
   directly into the BaseRewardPool.
5. Warp 14 days. Gauge accrual is timestamp-driven, LP-fee accrual is
   trade-driven (this 30-day window assumes ~$15M average daily volume,
   ~3% fee APR on a 4 bp fee).
6. `getReward(address(this), true)` to claim CRV + CVX + extras.
7. `withdrawAndUnwrap(staked, false)` to pull LP back; print balances.

## PnL math

Let `B` = crvUSD borrowed; `t = 14/365`; `y_fee` = pool swap-fee APR,
`y_crv` = CRV emissions APR (gauge-weighted), `y_cvx` = CVX cliff factor,
`y_borrow` = LLAMMA borrow APR.

```
fee_pnl_usd   = LP_share * pool_TVL * y_fee * t
emission_usd  = LP_share * pool_TVL * (y_crv + y_cvx) * t
borrow_cost   = B * y_borrow * t
llamma_fee    = ~0 (collateral fee 0 bp on add_collateral)
swap_drag     = ~0 (no swap on entry; all-in via LP add)
```

At fork values (`y_fee=3.2%`, `y_crv+y_cvx=5.1%`, `y_borrow=6.0%`,
LP share = `crvUSD_added / pool_TVL` ≈ 0.5%, pool TVL ~$48M, `B ≈ $230k`):

```
14-day fee_pnl   ≈ 230_000 * 0.032 * 14/365 ≈ $283
14-day emissions ≈ 230_000 * 0.051 * 14/365 ≈ $450
14-day borrow    ≈ 230_000 * 0.060 * 14/365 ≈ $529
14-day net       ≈ +$204 before gas
```

## Block pinned

**20_650_000** (Sep 2024).

## Risks

- **Convex shutdown.** If `pi.shutdown == true` the deposit reverts.
- **CRV/CVX price drift.** Emissions are priced at the *claim* moment; a
  CRV crash inside the 14-day window slashes the headline emissions APR.
- **LLAMMA soft-liq.** Same caveat as F05-07.
- **Single-sided LP-add slippage.** Adding 230k crvUSD into a $48M pool
  moves price by ~25 bp; that price impact is *baked into* the LP shares
  minted. Removing later via `remove_liquidity_one_coin` faces the same
  drag.
- **Gauge weight rebalance.** If CRV holders shift emissions away from
  the crvUSD/USDC gauge mid-window, headline emissions APR falls.

## Result

Status: **theoretical**. 14-day net on $510k WETH principal: **+$50 to
+$400** before gas (~600k gas at 15 gwei ≈ $25). The trade is *thin*
margin and best run continuously with rebalance cadence.
