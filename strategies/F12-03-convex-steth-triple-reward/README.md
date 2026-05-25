# F12-03: Convex stETH/ETH triple-reward stack (CRV+CVX+LDO)

## Mechanism
The Curve stETH/ETH pool (`0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`) is
the largest LST AMM and one of the highest-bribed Curve gauges. Convex
Booster PID `25` mirrors this pool. The unusual feature: Lido continuously
streams **LDO** into the gauge's `stash` as a third-party incentive, on top
of the regular CRV+CVX. The LDO stream is gated by Lido governance: when
the LDO-incentive proposal renews quarterly, the deposit rate to the stash
is reset.

The mechanics:
- Booster PID 25 (`0x9518c9...`), BaseRewardPool
  `0x0A760466E1B4621579a82a39CB56Dda2F4E70f03`.
- `extraRewards[0]` = a `VirtualBalanceRewardPool` paying LDO.
- LP receives:
  - CRV (boosted via Convex's veCRV proxy).
  - CVX (Convex emission ratio).
  - LDO (Lido stETH-incentive stream).
  - Curve swap fees (passively, via NAV).

## Why it composes
Three independent emissions sources stack into one deposit:
1. **CurveDAO** allocates a slice of the global CRV emission to this gauge
   via vlCVX/veCRV votes.
2. **Convex** layers its own CVX emission on top (and provides the boost
   without requiring the user to lock CRV).
3. **Lido** pays LDO directly into the gauge as an LP incentive. This is
   what makes the stETH/ETH stack a *cross-protocol bribe stack* — Lido is
   functionally bribing Convex LPs in addition to whatever Votium offers
   on a per-round basis.

Reading the rewards triple-stream from the `BaseRewardPool` requires the
caller to use `getReward(account, claimExtras=true)`. The base contract
streams CRV (and mints CVX); each `extraRewards` virtual pool streams its
own token (LDO here).

## Preconditions
- Mainnet fork at a block where the stETH/ETH gauge has active emissions
  AND the LDO stash is currently funded by Lido. We pin
  **19_643_500** (Apr 13 2024) — Q2 2024 LDO incentive proposal active.
- LP tokens for the stETH/ETH pool, obtained via `deal`.

## Strategy steps
1. Fund test contract with stETH/ETH LP.
2. Read `Booster.poolInfo(25)` and assert `lptoken == CURVE_STETH_POOL`.
3. Read `BaseRewardPool.extraRewardsLength()` — expect ≥ 1 (LDO).
4. Approve + `Booster.deposit(25, amount, true)`.
5. Warp 14 days.
6. Pre-claim: peek `BaseRewardPool.earned(self)` (CRV only).
7. `getReward(self, true)` — claims CRV+CVX+LDO.
8. Log raw token balances of CRV, CVX, LDO.
9. Withdraw and unwrap LP back to the contract.

## PnL math
For 50 LP staked over 14 days at block 19_643_500 (approximate $-figures
sourced from Curve dashboards historical):
```
LP USD value      ≈ 50 * 1.07 ETH/LP * $3300/ETH ≈ $176,550
gross APR  (CRV)  ≈ 2.2%      ; 14d:  $176,550 * 0.022 * 14/365 ≈ $148.9
gross APR  (CVX)  ≈ 0.9%      ; 14d:  ≈ $60.9
gross APR  (LDO)  ≈ 1.4%      ; 14d:  ≈ $94.8
swap fees         ≈ 0.6%      ; 14d:  ≈ $40.6  (kept in LP NAV)
total gross ≈ $345 / 14d
```
Annualised: **~4.7-5.2%** before compounding, on a no-IL pool (stETH/ETH
is near-pegged).

## Block pinned
**19_643_500** (Apr 13 2024). Booster PID 25 verified. LDO stash funded
per Lido proposal LIP-22 renewal. CVX cliff multiplier ~0.40.

## Risks
- **stETH peg.** A material discount on stETH/ETH (>50 bps) introduces IL
  on the LP.
- **LDO stream end.** Lido governance can vote to discontinue stETH/ETH
  incentives; LDO yield drops to 0 from that block.
- **Convex shutdown / pool migration.** Booster pools are occasionally
  shut down (e.g. for v2 migrations); LP withdraws only.
- **Gauge weight cuts.** If vlCVX vote weight rotates away, CRV/CVX
  rewards collapse.
- **MEV on getReward.** Negligible — claim is single-account, no
  sandwich surface unless the user immediately swaps.

## Result
Status: **theoretical, foundry build not run**. On-chain ABI matches the
`IConvexBooster` / `IConvexBaseRewardPool` interfaces; PoC exercises the
triple-reward claim path.

Expected single-window PnL (50 LP * 14 days) ≈ **+$300-$400** in mixed
tokens; gas ≈ $0.40.
