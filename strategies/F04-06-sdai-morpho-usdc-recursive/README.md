# F04-06: sDAI -> Morpho sDAI/USDC -> Curve 3pool recursive loop

## Mechanism

Three-mechanism Maker-anchored loop:

1. **sDAI** — Maker's ERC-4626 DSR-bearing token. Collateral that pays DSR
   while it sits posted.
2. **Morpho Blue sDAI/USDC isolated market** — Variable USDC borrow against
   sDAI at **86% LLTV**. Independently parameterised from Spark (Morpho's
   permissionless market creation is the *only* reason this LLTV is 12 pp
   above Spark's 74% sDAI LTV).
3. **Curve 3pool** — Recycles the borrowed USDC into DAI so the loop can
   re-enter sDAI on each turn. This replaces the same-token DAI hop used by
   F04-02 / F04-03 with a USDC-leg that has measurable but small slippage
   (~1-3 bps at meaningful notionals on 3pool).

The thesis: at 86% LLTV * 80% safety, each loop adds 0.688x of the prior
collateral; 4 iterations give ~2.9x leverage on the seed equity. Spark's
74% LTV with the same safety yields only ~2.5x. The extra 0.4x of leverage on
DSR is worth more than the ~30 bp round-trip Curve cost as long as DSR -
Morpho_USDC_borrow > 0.3% / leverage ≈ 0.1% net.

## Why it composes

Three things only this stack can do simultaneously:

- sDAI is the *only* DSR-passthrough that survives being moved into a non-
  Maker money market. Morpho allows it natively because the oracle is just
  `convertToAssets`.
- Morpho's permissionless markets let curators ship sDAI/USDC at 86% LLTV —
  there is no Aave/Spark equivalent. Aave hasn't onboarded sDAI as collateral
  at all (only the 2023 governance proposal exists).
- Curve 3pool is the canonical USDC<->DAI pool with deep liquidity (~$80M+
  across DAI-USDC at the pinned block). A single hop USDC->DAI moves 200k
  notional at <5 bps slippage, well inside the loop's positive-spread budget.

## Preconditions

- Morpho sDAI/USDC market exists with `LLTV >= 0.86e18`. Verified in
  `setUp()` via `Morpho.idToMarketParams`.
- 3pool has enough DAI/USDC balance for a 200k-1M notional swap at <0.5% slip.
- DSR APY > Morpho USDC borrow APY + 30 bp (the Curve slippage budget * 2
  per iteration). At block 20_900_000 (Oct 2024): DSR ~6.5%, Morpho USDC
  borrow ~5.5% -> positive spread of 100 bps.

## Strategy steps

1. Pin fork to **block `20_900_000`** (Oct 2024).
2. Seed 200k DAI -> sDAI.
3. `Morpho.supplyCollateral(sDAI, all_shares)`.
4. Loop 4 times:
   - Compute max debt = `collateral_value * 0.86 * 0.80`.
   - `Morpho.borrow(USDC, delta_debt)`.
   - `Curve.exchange(USDC, DAI, amount, min_dy = 99.5% * amount)`.
   - `sDAI.deposit(daiOut)` and `supplyCollateral` the new shares.
5. Warp 30 days, force `pot.drip()` and `morpho.accrueInterest()`.
6. Unwind: withdraw collateral incrementally, redeem sDAI -> DAI, swap to
   USDC on 3pool, repay Morpho debt.

## PnL math

```
APY_net = L * DSR_APY - (L - 1) * Morpho_USDC_borrow_APY - 2 * L * curve_slip
```

With `L = 2.9x`, `DSR = 6.5%`, `Morpho_USDC_borrow = 5.5%`, `curve_slip = 0.03%`:
`APY_net = 0.0290 * 0.065 * ... = 0.065 + 1.9 * 0.01 - 5.8 * 0.0003`
        = `0.0840 - 0.00174 = 8.26%` on equity (vs 6.5% naked sDAI).

Over 30 days on $200k seed: `200_000 * ((1.0826)^(30/365) - 1) ≈ $1_320`.

Gas: 4-iter loop is heavier than the Spark equivalent (extra Curve exchange
per iteration). ~2.4 M gas, ~$170 at 20 gwei / ETH=$2500. Net ≈ $1_150 over
30 days.

## Block pinned

`20_900_000` — Oct 2024. Morpho sDAI/USDC market is mature; DSR>Morpho-USDC
spread is solid.

## Risks

- **Curve 3pool depeg.** If USDC/DAI is materially off 1.0 the recycle leg
  bleeds. The PoC's `min_dy >= 99.5%` guard reverts the swap rather than
  proceed at bad price — the loop simply truncates early and unwinds.
- **Morpho USDC IRM compression.** When USDC borrow demand on Morpho spikes
  the rate can exceed DSR; the spread inverts. PoC assertion bounds the
  worst-case at -2% of seed (Curve slip + one cycle of inverted carry).
- **Wrong market id.** Setup asserts `lltv >= 0.86e18`. If a curator
  re-parameterises or de-lists the market the setUp reverts before any state
  change. The id is inline-constant per the family rule.
- **Morpho liquidation hard-edge.** Morpho's pre-LIF liquidation is atomic
  and dust-aggressive. PoC stays at 80% safety frac (HF equivalent ~1.25).

## Result
Status: theoretical-historical-replay
Expected PnL: ~8.26% APY on equity (~$1,150 net per $200k seed over 30 days at DSR=6.5%, Morpho USDC borrow=5.5%, L=2.9x)

A 3-mechanism (sDAI + Morpho + Curve 3pool) recursive loop demonstrating that
the higher LLTV of permissionless Morpho markets dominates the same-DSR
strategy on Spark. PoC asserts leverage > 2.5x, seed preserved within 2% on
worst-case unwind, and net DAI growth on a 30-day warp when DSR > Morpho USDC
borrow.
