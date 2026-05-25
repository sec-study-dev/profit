# F12-01: Convex Booster LP loop on Curve frxETH/ETH (boosted CRV+CVX+FXS)

## Mechanism
Curve LPs earn the pool's swap fees plus a base CRV emission proportional to
the LP's share of the gauge. Stakers that hold veCRV can boost their own
emission by up to 2.5x via `working_balance`. **Convex** abstracts this:
every LP deposited into the `Booster` is forwarded to Convex's gauge proxy,
which holds a permanently-locked >450M veCRV position. All Convex depositors
therefore receive the maximum 2.5x boost without having to lock CRV
themselves. In addition, Convex layers `CVX` token emissions on top (with a
declining schedule tied to total CRV harvested) and forwards any
"extraReward" tokens streamed to the gauge (FXS, LDO, ANGLE etc).

For the **frxETH/ETH** Curve plain-pool (`A=1500`, fee 4 bps):
- LP token / pool: `0xa1F8A6807c402E4A15ef4EBa36528A3FED24E577` (token = pool).
- Convex Booster PID: `128`.
- Convex BaseRewardPool (crvRewards): `0xbD5445402B0a287cbC77cb67B2a52e2FC635dce4`.
- Reward streams on this pool:
  - **CRV** boosted (`0xD533…cd52`) — base emission.
  - **CVX** (`0x4e3F…9D2B`) — minted 1:1 with CRV at low totalCliff (~0.4x at
    block 19.6M).
  - **FXS** extra-reward (`0x3432…64D0`) — Frax incentives streamed at a
    flat rate, configured in the pool's `stash`.

## Why it composes
Three orthogonal yield primitives stack inside one Booster deposit:
1. **Curve swap fees** (passive, retained in LP NAV via `get_virtual_price`).
2. **Boosted CRV emission** (gauge weight × 2.5 × user share). Without
   Convex the user would have to lock 2,500 CRV per $1 LP exposure to reach
   the same boost.
3. **Convex CVX + extraReward streams** — these are bonus tokens on top of
   the boosted CRV. The CVX is fungible/sellable; the FXS extra reward is
   pool-specific and not available outside Convex.

The compounding loop:
```
   stake LP -> earn (CRV, CVX, FXS) -> swap to ETH/frxETH -> add liquidity ->
   restake LP -> ...
```
gives a hands-off ETH-denominated yield. Steady-state APY oscillated between
2-6% over 2023-2024 for the frxETH/ETH pool depending on gauge weight, with
spikes to 12-15% during high-bribe weeks.

## Preconditions
- Mainnet fork at a block where the frxETH/ETH pool exists, has non-trivial
  TVL, and the gauge is receiving emissions. Block **19_643_500** (Apr 13
  2024) satisfies all three: gauge weight ~0.4%, pool TVL ~$80M, CRV
  emission ~3% APR + CVX ~1.2% + FXS ~1% before fees.
- Some frxETH and WETH (or just LP tokens) to deposit. We obtain LP tokens
  directly via `deal` to skip the AMM-balance routing for the PoC.

## Strategy steps
1. Fund test contract with frxETH/ETH LP tokens (cheat-deal).
2. Approve and `Booster.deposit(128, amount, true)` — `stake=true` routes
   straight into the `BaseRewardPool` so a second `stake()` call is not
   required.
3. Warp forward `STEADY_DAYS` (e.g. 14 days). During this window the
   on-chain emission rate fixes the accrual; we read `earned()` for
   pre-warp and post-warp baseline.
4. Call `BaseRewardPool.getReward(self, true)` — claims CRV+CVX and all
   extra rewards (`claimExtras=true`).
5. Snapshot PnL: tracked-token deltas of CRV, CVX, FXS, and LP. ETH leg = 0
   (we never touch native ETH).

The PoC does **not** swap the reward tokens back to LP (compounding leg) so
that the per-token deltas remain individually visible in the PnL block. A
production strategy would route them through `Curve cvxFXS/FXS`, `Uni v3
CRV/WETH 1%`, `Uni v3 CVX/WETH 1%`.

## PnL math
Let `L` = LP staked (frxETH/ETH LP tokens, 18 dec), `T` = warp duration
(seconds), gauge inflation `r_CRV(t)` measured per pool per second.

Per warp window:
```
crv_earned  = L * r_CRV * 2.5 * T
cvx_earned  = crv_earned * cliff_multiplier   (~0.40 at block 19.6M)
fxs_earned  = L * r_FXS_stash * T            (independent from CRV)
swap_fees   ≈ L * fee_apr * T / yr           (accrued silently via virtual_price)
```

USD valuation (PriceOracle does not know CRV/CVX/FXS prices, so the PoC
manually tracks them and console-logs raw balances). Approximate spot
(block 19.6M): CRV $0.45, CVX $2.10, FXS $3.20.

For 100 LP (~$0.34M notional at vp≈1.005) and a 14-day warp at the gauge's
historical rate:
```
crv ≈ 100 * 0.03/365 * 14 * 2.5  ≈ 0.288 CRV  per LP -> 28.8 CRV total ≈ $12.96
cvx ≈ 28.8 * 0.40 = 11.52 CVX                          ≈ $24.19
fxs ≈ ~25 FXS (Frax incentive rate Apr 2024)            ≈ $80.00
gross ≈ $117 / 14d / $340k notional = 0.10% per 14d ≈ 2.6% APR
```
Plus an estimated 0.5% APR swap-fee accrual baked into LP price.

## Block pinned
**19_643_500** (Apr 13 2024). frxETH/ETH gauge weight ~0.41%, Convex PID 128
has been live since 2022. Verified by reading
`Booster.poolInfo(128).lptoken == 0xa1F8…E577` on Etherscan.

## Risks
- **Convex shutdown.** If the gauge is killed (CurveDAO vote), CRV emissions
  stop; the LP is still withdrawable but yield collapses.
- **CVX cliff cutoff.** CVX has a hard supply cap (100M); once reached the
  `cliff_multiplier` -> 0 and CVX emission stops permanently.
- **frxETH peg.** frxETH is a "vanilla" LST without a withdrawal queue; it
  pegs via the pool itself. In a depeg the LP value drops with the discount.
- **stash/extra-reward stop.** FXS streams to the pool stash are
  governance-configurable; Frax can pause incentives.
- **PoC simplification.** No reward swap-back; real APY needs CRV/CVX/FXS
  market liquidity, which is good (>$30M TVL on each) but has bps slippage.

## Result
Status: **theoretical, foundry build not run** (forge not installed in this
env). On-chain references verified: Booster `poolInfo(128)` shape, frxETH
pool address, BaseRewardPool ABI (read-only).

Expected net for 100 LP * 14 days at block 19_643_500:
- gross reward USD ≈ **$110-$130**
- gas ≈ 350-500k for stake+claim @ 20 gwei ≈ $0.30
- net USD ≈ **+$110 / 14d / 100 LP**
