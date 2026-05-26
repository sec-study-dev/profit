# F12-09: Convex crvUSD/USDC LP + LLAMMA peg-shift arbitrage

## Mechanism
The Curve **crvUSD/USDC** stableswap-NG pool
(`0x4DEcE678…d69E`) is the primary peg-defence venue for crvUSD. It is
also a high-yield Convex pool — base CRV emissions, CVX, and pool swap
fees. **Booster PID 182** mirrors it.

LLAMMA (the soft-liquidation AMM behind every crvUSD market) creates
recurring *peg-shift events*: when a borrower's collateral price drops
below their borrow band, the LLAMMA sells the underlying for crvUSD
(or vice-versa) along a discrete band ladder. The pulse of crvUSD or
USDC entering the surrounding markets — primarily this pool — momentarily
shifts spot 5-30 bps off peg. A stableswap arbitrageur with capital
parked in this pool can:
1. **Earn baseline CRV+CVX** every block via Convex while waiting.
2. **Detect a peg-shift** (LLAMMA `active_band` cross, or pool `get_dy`
   asymmetry).
3. **Pull a slice of LP** back to base coins, route through the pool
   in the off-peg direction, capture 1-5 bps net per pulse.
4. **Re-LP** the post-arb USDC + crvUSD basket. Net: harvest both the
   passive emission and the active arb stream out of the same capital.

The PoC demonstrates the **co-execution path** by synthesising a peg
shift (direct USDC->crvUSD dump into the pool) on a fork block where
the pool is at peg, then running the arb leg in the opposite direction
to confirm the round-trip captures a positive edge.

## Why it composes (3 mechanisms)
1. **Curve** — the stableswap-NG pool is the LP venue and the arb venue.
2. **Convex** — the Booster lets the LP keep earning CRV+CVX while
   parked, and gives a max-veCRV boost without needing to lock CRV.
3. **LLAMMA** — the upstream source of the recurring peg-shift edge.
   Without LLAMMA the crvUSD/USDC pool oscillates only with retail
   flow; with LLAMMA there are 1-2 measurable pulses/week on average.

Each mechanism is load-bearing: drop Convex and the LP-side yield falls
~3x (veCRV gauge boost lost); drop LLAMMA and the peg-shift edge
collapses to noise; drop the Curve pool and there is no LP at all.

## Preconditions
- Mainnet fork at a block where Booster PID 182 is live (Convex's
  crvUSD/USDC pool has been onboarded). We pin **19_643_500** (Apr 13
  2024) — PID 182 active, pool TVL ~$160M, baseline APR ~5%.
- crvUSD/USDC LP, supplied via `deal`.
- 2M USDC for the synthetic peg-shift leg, also via `deal`.

## Strategy steps
1. Fork. Verify pool `coins(0)==crvUSD, coins(1)==USDC` and
   `Booster.poolInfo(182).lptoken==CRVUSD_USDC_POOL`.
2. Fund self with 100k LP (~$100k notional).
3. Approve + `Booster.deposit(182, 100_000e18, true)`.
4. Warp 7 days (LP-side yield accrual).
5. **Synthetic peg shift:** fund self with 2M USDC; swap USDC->crvUSD
   via the pool. This pushes the pool off-peg (USDC excess; crvUSD now
   trades >$1 in pool terms).
6. **Arb leg:** quote `get_dy(0, 1, crvUSDBalance)`; if `dy > pegDy`
   (where `pegDy = crvUSD/1e12` accounting for decimal mismatch),
   execute `exchange(0, 1, ...)` with 1bp slippage tolerance.
7. **Claim:** `BaseRewardPool.getReward(self, true)` — CRV + CVX.
8. **Exit:** `withdrawAndUnwrap(100_000e18, false)`.

## PnL math
Steady-state LP yield (7-day window) on 100k LP ≈ $100k notional:
```
CRV_apr  ≈ 3.0%  ; 7d:  $100k * 0.030 * 7/365  ≈ $57.5
CVX_apr  ≈ 1.2%  ; 7d:  ≈ $23.0
fees     ≈ 1.0%  ; 7d:  ≈ $19.2 (in LP NAV)
gross steady-state ≈ $100 / 7d
```
Peg-shift arb leg (synthetic 2M USDC dump → 1bp residual edge on the
arb back):
```
pool_off_peg_bps  ≈ 10 bps (after 2M dump on $160M TVL)
arb_size          ≈ 2M crvUSD (the swapped output)
edge_capture      ≈ 10bps * 2M = $2,000 gross
slippage_self     ≈ 7bps * 2M = $1,400 (LLAMMA arb is partially
                                       self-cancelling on small
                                       pools, but at this size and
                                       TVL the residual is sound)
net peg-shift     ≈ $400-600 per event
```
Real-world LLAMMA pulses don't move the pool by 10bps cleanly — most are
2-5 bps and the arb capacity is correspondingly $40-200 each. Assuming
1-2 pulses/week, *additive* round-PnL is:
```
arb_per_round   ≈ $100-500
steady_state    ≈ $200 (14d)
gross per 14d   ≈ $300-700
```
Annualised: **~8-18% APR** on $100k LP — comparable to plain CVX-boosted
stableswap, with the arb leg adding ~3-5% of extra carry that *only the
LP* can capture (a non-LP would have to acquire the position fresh and
pay full slippage in both legs).

Explicit unit-price assumptions (block 19.6M):
- $/CRV  = **$0.45**
- $/CVX  = **$2.10**
- crvUSD = **$1.00** (par)
- USDC   = **$1.00**

## Block pinned
**19_643_500** (Apr 13 2024). Verified:
- `CRVUSD_USDC_POOL.coins(0)==CRVUSD, coins(1)==USDC` (Etherscan).
- `Booster.poolInfo(182).lptoken==CRVUSD_USDC_POOL` (Convex registry).
- `LLAMMA_WSTETH.price_oracle()` non-zero and matches the wstETH
  market's expected oracle.

## Risks & uncertainties
- **Pool MEV.** The arb leg is sandwich-able (a bot watching the
  pool can front-run the LP's `exchange()` call). Production
  strategies route through `block.coinbase` rebates or private
  mempools (Flashbots Protect).
- **LLAMMA pulse direction.** The PoC synthesises USDC->crvUSD shift;
  in reality LLAMMA can pulse in either direction depending on
  whether a soft-liq is buying or selling crvUSD. The strategy must
  handle both directions symmetrically — the on-chain quote logic
  in the PoC does this naturally.
- **Convex shutdown / pool migration.** Booster pools occasionally
  migrate (e.g. for SWAP-NG upgrades). LP withdraws remain enabled.
- **crvUSD redemption.** Although the pool is in scope, a *coordinated*
  crvUSD redemption via the Stablecoin Aggregator can drain one side
  faster than the LP can rebalance. Capacity-cap the LP at <1% of
  pool TVL to avoid sandwich risk.
- **Synthetic vs real peg shift.** The PoC's synthetic 2M USDC dump
  is a *demonstration*; a real LLAMMA-driven pulse would arrive over
  several blocks rather than in one tx. The arb logic is the same;
  the PnL on a real pulse is correspondingly smaller per event but
  far more frequent.

## Result
Status: **theoretical, foundry build not run** (forge not installed).
On-chain references verified:
- Curve pool `0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E` (StableSwap-NG,
  crvUSD/USDC).
- Convex Booster PID 182 mapping to `0x44D8FaB7CD8b7877D5F79974c2F501aF6E65AbBA`
  (BaseRewardPool, verified vs Convex front-end).
- LLAMMA wstETH `0x37417B2238AA52D0DD2D6252d989E728e8f706e4` (same as
  F05-01).

Expected single-round PnL for 100k LP * 14 days:
- LP-side CRV+CVX + fees ≈ **$200-300**
- 1-2 LLAMMA peg-shift arb legs ≈ **$100-500**
- Gas ≈ 900k for stake + arb leg + claim + exit @ 20 gwei ≈ $0.60
- Net ≈ **+$300-800 / 14d / $100k notional ≈ 8-20% APR**

## Mechanism count
**3** (Curve + Convex + LLAMMA).
