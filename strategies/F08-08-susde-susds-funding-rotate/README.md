# F08-08: sUSDe → sUSDS funding rotation when carry inverts (2-mech)

## Mechanism

sUSDe and sUSDS are both yield-bearing stablecoins but their yield
*sources* are independent:

- **sUSDe** = ETH/BTC perp funding rate paid out via a delta-neutral
  basis trade run by Ethena. Highly procyclical with crypto sentiment:
  rate ranges from > 40% in bull regimes to < 5% (and historically
  negative) in deep funding-flip regimes.
- **sUSDS** = Sky Savings Rate. Backed by Maker's RWA portfolio
  (BlackRock-managed Treasury bills) and the Sky governance vote.
  Range ~5-12% in 2024, mean-reverting to short-end T-bill rates.

The two yields are **uncorrelated** with crypto. When sUSDe APY drops
below sUSDS APY (plus rotation cost), the optimal carry asset rotates.

### Detection

```
susde_30d_apy = (nav_per_share_now / nav_per_share_30d_ago - 1) * 365/30
susds_apy     = compound(ssr, 365*24*3600)  // ssr is RAY/sec
rotation_threshold = susds_apy + rotation_cost_bps
if susde_30d_apy < rotation_threshold: ROTATE
```

Rotation cost ≈ Curve fees (3 swaps × ~4 bps = 12 bps) + DaiUsds
converter (0 bps) + sUSDS deposit (0 bps) ≈ 12 bps. So the rotation
trigger is roughly `susde_apy < susds_apy + 12 bps`.

### Path

```
sUSDe (1M shares)
  -> ISUSDe.redeem(shares) or cooldownShares + 7d wait
  -> ~1.X M USDe (NAV at exit time)
  -> Curve USDe/USDC  -> X M USDC
  -> Curve 3pool USDC/DAI -> X M DAI
  -> DaiUsds.daiToUsds (1:1)  -> X M USDS
  -> ISUSDS.deposit(USDS)     -> X M sUSDS
```

After 30 days of sUSDS accrual at SSR, the PoC reads
`convertToAssets(shares)` to surface the realised USDS NAV.

## Why it composes (2-mech)

1. **Ethena sUSDe** — the exit leg. Reads NAV via `convertToAssets`,
   then exits either via 4626 redeem (instant if not gated) or via
   cooldownShares + 7d wait (canonical Ethena path).
2. **Sky sUSDS** — the entry leg. Reads SSR via `ssr()`, deposits via
   `4626.deposit(USDS)`. The Sky Savings Rate is updated by Sky governance
   votes and is committed in `chi` which accrues per `rho` second since
   the last `drip()`.

The Curve + DaiUsds converter legs are glue, not separate mechanisms in
the carry sense — they're standard stable-stable swaps with negligible
spread risk.

## Strategy steps

1. `_fund(sUSDe, this, 1M shares)` — seed an existing sUSDe position.
2. Read `convertToAssets(1e18)` and `ssr()` to surface both rates.
3. Approvals for Curve USDe/USDC, Curve 3pool, DaiUsds, sUSDS.
4. Exit sUSDe via `redeem` (4626) — try/catch with cooldown fallback.
5. USDe → USDC → DAI → USDS → sUSDS via the four-leg path.
6. `vm.warp(30 days)` + `sUSDS.drip()`.
7. Log `sUSDS.convertToAssets(shares)` post-30d for comparison.

## PnL math

### Pre-rotation (counterfactual: hold sUSDe)

If sUSDe APY is at 5% (the regime that triggers rotation):
```
30d_sUSDe_growth = 1M * 0.05 * 30/365 = $4.11k
```

### Post-rotation (sUSDS at 7.5% SSR)

```
rotation_cost  = 1M * 12 bps = $1.2k (one-time)
30d_sUSDS_growth = 1M * 0.075 * 30/365 = $6.16k
net 30d = -1.2k + 6.16k = $4.96k
```

### Differential

```
rotate_benefit_30d = 4.96k - 4.11k = $0.85k (~8.5 bps)
```

The benefit scales linearly with the APY gap and quadratically with
duration: a 250 bps APY gap held for 90 days yields ~62 bps net.

### Notes on the 7-day cooldown

When the `redeem` path is gated (cooldownDuration > 0 and Ethena's
instant-redeem fuse is set off), the strategy must wait 7 days. The
foregone carry during cooldown is:

```
cooldown_carry_loss = 1M * 0.05 * 7/365 = $0.96k
```

This adds to rotation_cost, raising the trigger threshold by ~10 bps:
`susde_apy < susds_apy + 22 bps`. For tighter gaps, the AMM-sell exit
becomes preferable even at a small AMM discount.

## Block pinned

**21_400_000** (~Dec 2024). At this block:
- sUSDe trailing 30d APY ≈ 7-9% (compressed regime).
- sUSDS SSR ≈ 7.5% (Sky governance vote in late 2024).
- Carry gap was at times *negative* (sUSDS > sUSDe), triggering the
  rotation thesis.

## Risks

- **Misjudgment on persistence**: sUSDe APY mean-reverts to perp
  funding, which is procyclical. A rotation right before an ETH bull
  rally locks in the lower sUSDS yield while sUSDe spikes back to >20%.
  Counter: rebalance every 14-30 days based on trailing realised APY.
- **Cooldown 7d window**: NAV risk on USDe during the 7d wait. USDe
  could depeg below $1, reducing the claim value.
- **Curve slippage at scale**: 3M+ rotations need multi-block staged
  execution. PoC sizes at 1M which is within the 5 bps slippage band.
- **sUSDS smart-contract / Sky governance risk**: SSR can be set to
  zero by Sky governance. The pre-existing deposits would simply stop
  earning until a new SSR is committed.
- **DaiUsds converter pause**: the converter is a Maker MOM-style
  contract; emergency shutdown halts conversions. Falls back to
  alternative DAI→USDS paths (e.g. Spark sDAI redemption + sUSDS).

## Result

Status: theoretical. Forge build not run.

Expected PnL: **~+8.5 bps net 30d benefit per 100 bps of APY gap**
versus the counterfactual hold-sUSDe baseline. On a 1M USDe position
with a 250 bps gap held for 90 days, ~+62 bps = $620 net of fees.
The strategy is *defensive* (avoid the lower-yielding asset), not
alpha-generating in absolute terms.
