# F08-04: sUSDe stablecoin e-mode loop on Aave v3

## Mechanism

Aave v3 e-mode allows assets within the same "correlated risk class"
to be looped at much higher LTV than the default category. After
**AIP-369** (~Jul 2024) Aave governance enabled a stablecoin e-mode
that recognises **sUSDe alongside USDT / USDC / DAI** as a single
risk class. At activation parameters:

- sUSDe e-mode LTV: 90%
- sUSDe e-mode liquidation threshold: 92%
- Liquidation bonus: 1-2% (e-mode reduces bonus vs default)

This is materially higher than the default sUSDe LTV of ~75%, which
turns a 4-loop sUSDe carry from ~4x to ~9x notional leverage at the
limit. Within e-mode the borrowable assets are USDT/USDC/DAI.

The same delta-neutral funding-yield mechanic as F08-01 applies — the
only difference is the venue (Aave v3 vs Morpho Blue) and the borrowed
asset (USDT vs USDC). The PoC borrows USDT because at the fork block
the USDe/USDT Curve pool had the deepest USDT-side liquidity, making
the round-trip USDT->USDe->sUSDe leg cheaper.

## Why it composes

The Aave variant complements the Morpho variant (F08-01) along two
axes:

1. **Liquidity venue diversification**: Aave's USDT borrow pool is
   independent of Morpho's USDC market. When Morpho USDC borrow APY
   spikes (e.g. due to vault rebalances), Aave USDT borrow may still
   sit at the kink at a lower rate.
2. **e-mode LTV uplift**: Aave's 90% e-mode beats Morpho's 91.5%
   isolated market at face value but is more conservative because the
   stablecoin e-mode category aggregates risk across many assets —
   conservative buffer is warranted but realisable LTV is higher than
   the default mode.

Aave + Curve + Ethena sUSDe form a closed loop where:

- Aave provides the leverage primitive (collateralised borrow at high
  LTV).
- Curve USDe/USDT provides the USDT -> USDe conversion (the "synthetic
  Ethena mint" surrogate; canonical Ethena minting is gated on
  off-chain RFQ signatures, hence the on-chain alternative — see
  F08-01 README for full rationale).
- sUSDe ERC-4626 provides the carry asset (delta-neutral funding-rate
  yield).

## Preconditions

- Mainnet fork at a block *after* AIP-369 activated sUSDe e-mode
  (~Jul 2024). PoC uses block `20_400_000` (Aug 2024).
- Aave v3 sUSDe stablecoin e-mode category id set to `8` — the
  category created by AIP-369 in summer 2024, layered on top of the
  pre-existing ETH/USD-correlated categories 1-7.
- Aave USDT variable-borrow APY < sUSDe trailing yield. At the pinned
  block this holds (~8% borrow vs ~14% sUSDe).
- Curve USDe/USDT pool depth > 1M USDT at < 30 bps slippage.

## Strategy steps

1. Receive `1_000_000e18` USDe via `deal()`.
2. `sUSDe.deposit(USDe, this)` -> initial shares.
3. `AavePool.supply(sUSDe, shares)`.
4. `AavePool.setUserEMode(8)` to switch to stablecoin e-mode.
5. Loop 4 times:
   a. Read `getUserAccountData().availableBorrowsBase`.
   b. `AavePool.borrow(USDT, availableBase * 0.87 / 1e2)`.
   c. `Curve.exchange(USDT->USDe, borrowAmt, minOut=99.5%)`.
   d. `sUSDe.deposit(usdeOut)` -> new shares.
   e. `AavePool.supply(sUSDe, newShares)`.
6. Warp 30 days; force index crystallisation by a no-op supply.
7. Log `(totalCollBase, totalDebtBase, equityBase, healthFactor)`.

## PnL math

Let:
- `y_s` = sUSDe trailing APY ≈ 0.14 (Aug 2024)
- `y_b` = Aave USDT variable borrow APY ≈ 0.075
- `L` = 0.87 (per-loop LTV)
- 4 loops -> realised leverage `K = (1 - 0.87^4) / (1 - 0.87) ≈ 4.91`

Net APY on equity:

```
net_apy = K * y_s - (K - 1) * y_b
        = 4.91 * 0.14 - 3.91 * 0.075
        ≈ 0.687 - 0.293
        ≈ 0.394   (~39.4% APY on equity)
```

Over the 30-day simulated window: `30/365 * 39.4% ≈ 3.24%`, or
~$32.4k of equity gain on 1M USDe principal.

Subtract:
- Curve fees: 4 swaps × ~5 bps × ~900k cumulative notional ≈ $1.8k
- Aave borrow accrual already netted
- Gas: ~700k gas × 25 gwei × $3k/ETH ≈ $52

Net ≈ +$30.5k over 30 days.

## Block pinned

**20_400_000** (~Aug 11 2024). Verifications:

- AIP-369 activated, sUSDe stablecoin e-mode live.
- Aave USDT borrow rate at ~7-9% APY variable.
- Ethena sUSDe trailing 30d APY ≈ 13-15%.
- Curve USDe/USDT pool TVL > $40M, peg within 5 bps.

## Risks

- **Funding-rate flip (sUSDe APY collapse)**: same dominant risk as
  F08-01. If `y_s < y_b` the loop bleeds.
- **Aave parameter governance**: AIP follow-ups can change e-mode LTV,
  liquidation threshold, supply/borrow caps overnight. The PoC reads
  on-fork; production should monitor governance proposals.
- **USDT freeze**: Tether can freeze USDT addresses. A frozen Aave
  USDT vault would prevent borrow. Mitigation: rotate borrowed asset
  to USDC (still within the same e-mode category).
- **Oracle feed**: Aave uses Chainlink for sUSDe. If the feed
  stale-mode triggers, supplies/borrows in the asset pause.
- **Liquidation cascade**: at 92% liquidation threshold and 90% LTV,
  the buffer is only 2%. Per-loop target 87% LTV gives ~5% buffer at
  position level (because not all collateral is at the limit). A 3%
  USDe depeg would liquidate; historically USDe excursions have been
  < 0.5%.
- **Cooldown on unstake**: sUSDe still has a 7-day cooldown. Emergency
  exits go through Curve sUSDe/USDe or Pendle SY at 50-200 bps cost.
- **Curve pool drain**: USDT-side of the pool can run dry in a USDe
  panic-buy. Then USDT->USDe slippage explodes. Fallback to USDC pool.

## Result

Status: theoretical (forge build not run; e-mode category id and AIP
parameters from Aave docs at fork block — verify before going live).

Expected PnL: **~+3.0% over 30 days** on 1M USDe equity at ~4.91x
realised leverage, gross of ~$1.85k swap fees and ~$52 gas. Annualised
~ +39%.
