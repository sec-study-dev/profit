# F02-08: weETH leveraged on Fluid `weETH-ETH<>wstETH` smart-collateral vault

## Mechanism
**Fluid (Instadapp) Smart-Collateral** is a vault type where the collateral leg
is a *Fluid DEX LP* (not a single token): the user posts an internal weETH-ETH
pool LP, and borrows wstETH against it. The LP earns DEX trading-fee yield in
addition to the underlying staking yield, and the borrow asset (wstETH) is a
yield-bearing LST, so the "borrow cost" is **negative** in net-yield terms
when wstETH-rate > Fluid wstETH-borrow rate.

Composition stack:
1. **EtherFi (weETH)** — points-emitting LRT (EtherFi loyalty + EL pts).
2. **Fluid Smart-Collateral** — weETH-ETH DEX LP as collateral, wstETH-as-debt;
   the LP earns DEX fees while the wstETH debt accrues Lido staking yield
   (a *negative* borrow rate in stETH terms).
3. **Curve stETH/ETH pool** — needed to convert borrowed wstETH back to ETH for
   the next loop iteration (Fluid does not natively unwrap on borrow).

Net effect: a leveraged weETH position where the borrow leg is a wstETH-yield
*credit* rather than a cost, while still earning EtherFi/EL pts on the bulk of
the levered weETH notional via the DEX LP.

## Why it composes
- **Fluid's smart-collateral is a unique primitive.** Unlike Aave/Morpho where
  collateral is a single token, Fluid's vault treats a paired LP position as
  collateral, so the strategy captures DEX trading-fee revenue (~50-200 bps
  APR on weETH-ETH at scale) on top of the underlying staking rates.
- **Negative-rate-borrow.** Borrowing wstETH (a yield-bearing LST) means the
  debt balance grows by Lido stETH yield. As long as Fluid's wstETH-borrow APR
  is less than Lido's accrual (~3%), the net debt-cost is **negative** in
  underlying-ETH terms — rare on lending markets.
- **Three protocols compose:** EtherFi (mint LRT) + Fluid (LP-as-collateral
  vault) + Curve (atomic stETH↔ETH swap for the loop). The Curve leg is
  required because Lido's withdrawal queue is multi-day, so the only same-tx
  unwrap path is the secondary market.

## Preconditions
- Block: 21_200_000 (Nov 2024) — Fluid VaultT2 weETH-ETH<>wstETH vault is live
  and deposit cap not full.
- Fluid Liquidity Layer accepts wstETH borrow at ~2.0-2.7% APR.
- weETH-ETH internal Fluid DEX pool active (post-Fluid-DEX launch).
- Curve stETH/ETH pool has > 5000 ETH liquidity (it does — >25k ETH at this block).

## Strategy steps
1. Receive 100 WETH equity.
2. Unwrap WETH → ETH; split 50 ETH → submit to Lido for stETH → wrap to wstETH;
   the other 50 ETH stays as raw ETH (for the LP ETH leg).
3. **Open the Fluid vault** (`operate{value: 50e18}(0, +wstETHAmount, 0, this)`):
   the vault internally adds the wstETH + ETH legs to the weETH-ETH<>wstETH
   smart-collateral DEX position, mints an NFT.
4. **Leveraged loop** (3-4 iterations):
   a. `operate(nftId, 0, +borrowAmt, this)` — borrow wstETH from Fluid.
   b. Unwrap wstETH → stETH → swap on Curve stETH/ETH to ETH.
   c. Split borrowed ETH 50/50 again: half stays ETH, half → stETH → wstETH.
   d. `operate{value: ethHalf}(nftId, +wstHalf, 0, this)` — deposit both legs
      back into the smart-collateral vault, increasing the LP collateral.
5. Hold; PnL accrues from:
   - Lido yield on the wstETH leg of the LP (≈ +3% APR).
   - DEX trading fees on the LP (≈ +0.5-2% APR depending on activity).
   - EtherFi + EL points (off-chain).
   - Minus Fluid wstETH-borrow rate (≈ -2% APR) on the leveraged wstETH debt.

## PnL math
Inputs: 100 ETH equity, ~3x leverage, 1y hold.

```
End state (approx):
  LP collateral (weETH-ETH<>wstETH) ≈ 300 ETH-equiv
  wstETH debt                       ≈ 200 wstETH (≈ 235 ETH-equiv at rate 1.176)
  net equity                        ≈ 100 ETH

Cash leg (1y):
  Lido yield on full underlying:    300 × 3.0%        = +9.0 ETH
  Fluid DEX fee on the LP:          300 × 1.0%        = +3.0 ETH
  Fluid wstETH-borrow cost (APR ≈ 2.2%):
                                    200 wstETH × 2.2% × rate(1.176) = -5.2 ETH
  Net cash                         ≈ +6.8 ETH (~6.8% on equity, ~$20.4k/yr at $3k ETH)

Point leg (1y, on the weETH-fraction of the LP — say half of the 300 LP
notional, i.e. 150 weETH-equiv):
  EtherFi pts:   150 × 5k/ETH/day × 365 = 274M pts
    @ $0.00002/pt (post-S2 dilution) ≈ $5,500
    @ $0.00005/pt (post-S1 multiple) ≈ $13,700
  EL rs-pts:     150 × 1 ETH-day × 365   = 54,750 ETH-days
    @ $0.5/ETH-day                     ≈ $27,400
    @ $2/ETH-day (S1 realised)         ≈ $109,500
```

Outcome on 100 ETH ($300k) equity (1y):
- Cash only: **+$20k** (+6.8%) — best cash carry in family F02
- Cash + base points: **+$55-75k** (+18-25%)
- Cash + bull points: **+$140k+** (+47%+)

The cash leg is what distinguishes this strategy: F02-08 is the **only F02 PoC
with positive cash-only PnL**, because the wstETH borrow leg is yield-bearing
(unlike WETH or USDC borrow legs which are pure cost).

## Block pinned
- Fork block 21,200,000 (Nov 2024).
- Fluid VaultT2 `weETH-ETH<>wstETH` smart-collateral vault:
  `0xb4a15526d427f4d20b0dAdaF3baB4177C85A699A` (verified at
  https://etherscan.io/address/0xb4a15526d427f4d20b0dadaf3bab4177c85a699a).
- Fluid VaultFactoryT1: `0x324c5Dc1fC42c7a4D43d92df1eBA58a54d13Bf2d`.
- ETH sentinel for Fluid: `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.
- Curve stETH/ETH pool: `Mainnet.CURVE_STETH_POOL`.

## Risks
- **Smart-collateral repricing.** Fluid's LP token is internally priced via the
  DEX pool. A weETH/stETH/ETH oracle gap or pool imbalance can liquidate.
- **wstETH borrow-rate spike.** Fluid's IRM can spike to 8%+ during demand
  shocks; net carry inverts.
- **Lido yield reduction.** If Lido staking APR drops below Fluid's wstETH
  borrow APR, the negative-cost-borrow advantage disappears.
- **EtherFi pts on LP-locked weETH.** EtherFi's tracker may or may not credit
  weETH locked inside Fluid's LP (depends on the snapshot logic). At minimum,
  the snapshot block matters.
- **DEX-LP rebalancing risk.** Fluid's internal DEX rebalances within the
  vault; a stress event in the weETH-ETH pair could expose the position to
  impermanent loss.
- **Multi-step unwind.** Closing requires wstETH-debt repayment from outside
  Fluid → Curve swap → unwrap → wstETH; ~5 contract calls; gas-sensitive.

## Result
Status: **theoretical**. Mechanics reproducible at the pinned block. Distinctive
because the cash leg is **positive** — most F02 strategies are net-negative
cash + positive points.

PnL range (1y, 100 ETH equity = $300k):
- Cash only: **+$15-25k** (+5-8%)
- Cash + conservative points: **+$50-80k** (+17-27%)
- Cash + bull points: **+$140-250k** (+45-83%)
- Bear (borrow-rate spike + point streams → 0): **-$10k** (modest downside)
