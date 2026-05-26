# F06-05: BOLD system-wide redemption arb via CollateralRegistry + DssFlash + Curve

3-mechanism strategy. **Family: F06 (Liquity v1/v2 / LUSD / BOLD)**.

## Mechanisms combined
1. **Liquity v2 CollateralRegistry redemption** (system-level, basket of all branches).
2. **Maker DssFlash** zero-fee DAI flashmint.
3. **Curve** — Stableswap-NG BOLD/USDC + 3pool + tricrypto2 unwind.

## Mechanism
Liquity v2's `CollateralRegistry.redeemCollateral(boldAmount, ...)` fans out
a single BOLD-redemption across **every** collateral branch, in proportion
to outstanding debt. Each unit of BOLD burned yields a *blended basket* of
{native ETH (from WETH branch), wstETH, rETH} priced at the per-branch
oracle minus the system redemption fee.

When BOLD trades below $1 on the Curve Stableswap-NG BOLD/USDC pool the
spread is:

```
profit_per_BOLD  =  (1 - R_v2)  -  BOLD_price_USDC
                 ≈  (1 - 0.005 - baseRate)  -  BOLD_curve_price
```

The arb path:

```
1) DssFlash    : DAI -> contract
2) Curve 3pool : DAI -> USDC
3) Curve NG    : USDC -> BOLD  (cheap leg)
4) Registry    : BOLD -> {ETH, wstETH, rETH} basket  (registry redemption)
5) Curve mix   : each collateral leg -> WETH -> USDT -> DAI
6) DssFlash    : repay DAI
```

Distinct from **F06-03**, which goes through a *single branch's* TroveManager
(deterministic ETH-only payoff). Here the redeemer gets all three v2 LSTs
proportionally — this matters because:
- The wstETH and rETH legs may have *different exit liquidity* than WETH.
- A redeemer of size `B` BOLD only burns `B / total_v2_debt × per_branch_debt`
  worth of debt in each branch, so the gas walk on each SortedTroves is
  small (good).
- The basket exposure means the strategy is implicitly long the
  cross-section of v2 collateral until the unwind leg completes.

## Why it composes
- **DssFlash** funds the BOLD-buy leg without capital lockup.
- **Curve Stableswap-NG** is the canonical BOLD AMM (TVL > $25M post-launch
  per Curve dashboard).
- **CollateralRegistry** is the only v2 contract that touches multiple
  branches in a single transaction — the system-redemption is uniquely a
  v2-mechanic.

## Preconditions
- BOLD/USDC < 0.997 on Curve.
- `CollateralRegistry.getRedemptionRateWithDecay()` ≤ 1%.
- Combined per-branch lowest-CR-trove debt absorbs `B` without crossing
  too many hops per branch.
- DssFlash `toll() == 0` and `maxFlashLoan(DAI) ≥ flashSize`.

## PnL math
For `flashSize = 2,000,000 DAI`, `BOLD_curve_price = 0.991`, `R_v2 = 0.006`:
```
bold_out      = 2_000_000 × (1 - 0.0004 dai->usdc) × (1 - 0.0004 usdc->bold) / 0.991
              ≈ 2_015_137 BOLD
basket_value  = bold_out × (1 - 0.006)  ≈ 2_003_046 (in USD, before unwind)
unwind_cost   = ~0.10% across three legs (wstETH/rETH legs include LST→ETH spread)
profit_dai    ≈ 2_003_046 - unwind_drag - flash_repay
              ≈ +1,000–3,000 DAI per 2M turn  (≈ +5–15 bps net)
```
Gas ≈ 2.0M @ 30 gwei = 0.06 ETH ≈ $200 → net ≈ $800–$2,800.

At deeper depegs (`BOLD_curve_price = 0.97`) net profit rises to ~$30k per
$2M turn, bounded by Curve depth.

## Block pinned
- `FORK_BLOCK = 22_500_000` (≈ mid-June 2025; first month with active v2
  troves post the May 2025 redeployment).

## Risks
- **Per-branch slippage divergence.** wstETH/rETH legs route through
  smaller pools than WETH; a basket redemption forces those legs even if
  they're momentarily illiquid.
- **Registry redemption fee** depends on system-wide BOLD outstanding, not
  per-branch. A baseRate spike from prior redemptions wipes the spread.
- **MEV.** The Curve buy leg is sandwich-able; bundle via Flashbots.
- **Pool address gating.** The exact post-redeployment BOLD/USDC Curve
  pool address is not yet under a stable Etherscan label; the contract
  gates and falls back to a telemetry-only path.

## Result
Status: **structurally ready** — uses verified BOLD + CollateralRegistry
addresses, gated only on the per-version BOLD/USDC Curve pool resolution.

PnL range:
- Tight peg (≤30 bps): +5–15 bps net, **$800–$2,800 per $2M turn**.
- Stress (≥100 bps): +50–150 bps net, capped by Curve NG depth.
