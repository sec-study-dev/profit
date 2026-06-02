# B08-08: Stable-pool triple-gauge stack — PCS + Thena + Wombat (3-mechanism)

## Mechanism
The USDe/USDC pair has live gauges on THREE independent protocols on BSC,
all subsidising the same underlying activity (stable LP for Ethena's USDe).
We deploy $1.5M across the three legs simultaneously:

1. **Thena stable gauge** — USDe/USDC stable AMM pair (Solidly fork), THE
   emissions at ~12 % APR.
2. **PCS v3 concentrated** — 0.01 % USDe/USDT pool, CAKE emissions via
   MasterChefV3 at ~9 % APR (same pattern as B08-03).
3. **Wombat single-sided** — USDe deposited into Wombat's stable pool,
   farm-staked into MasterWombat for WOM emissions at 6 % base, **2.5×
   boost via veWOM lock** → 15 % effective APR.

## Why it composes
- **Ethena's bribe budget** is paid into all three protocols to maintain
  USDe peg depth across the BSC stable surface. The bribe pie is split
  but the LP fee + token-emission tail is **additive**.
- **veWOM-boost** is a one-time capital lock ($20k locked WOM gives 2.5×
  boost on $500k USDe LP, ~25× capital efficiency on the boost cost).
- **No impermanent loss**: all three are USD-stable pairs, so the only
  drawdown is a USDe depeg event — uncorrelated to gauge mechanics.

## Preconditions
- USDe maintains < 50 bps depeg over 7-day epoch.
- All three gauges live and receive emissions at pinned block (PCS v3
  USDe/USDT pool, Thena stable USDe/USDC, Wombat USDe pool).
- veWOM accepts new 3-year locks with 2.5× max boost.

## Numbers (THE=$0.30, CAKE=$2.40, WOM=$0.10)
- Per-leg principal: $500 000. Total: **$1 500 000**.
- veWOM boost lock: 200 000 WOM = $20 000 (separate capital).
- Weekly yields:
  - Thena: $500k × 12 % × 7/365 = **$1 151/wk** = 3 836 THE @ $0.30.
  - PCS v3: $500k × 9 % × 7/365 = **$863/wk** = 360 CAKE @ $2.40.
  - Wombat (boosted): $500k × 15 % × 7/365 = **$1 438/wk** = 14 384 WOM
    @ $0.10.
- **Total: $3 452 / week ≈ 12.0 % blended APR on $1.5M.**
- Subtracting 25 bps slippage on each emission off-ramp: ~11.9 % net.

## Trade-off observation
- Single-protocol concentration on Thena 12 %: same APR but **3× pool
  concentration risk** — if Thena gauge weights shift, full position
  bleeds.
- Triple-stack diversifies protocol risk (one gauge can be depleted and
  the other two carry).
- veWOM lock is the only "captive capital" cost. Boost amortization:
  $20k locked WOM × 100 % opp cost = $200/week → still net positive on
  the $876/wk extra Wombat yield from boost (vs $562/wk unboosted).

## $/CAKE and $/THE primary metrics
- $/THE earned by holders of THE-emitting gauge: ~$0.3/THE realized.
- $/CAKE: ~$2.4/CAKE realized.
- $/WOM: ~$0.10/WOM realized.
- Blended emission cost per $ farmed: ~94 % of face value (6 % bleed to
  slippage + harvest gas).

## Risks not modelled
- USDe depeg: a 1 % depeg over an epoch would erase 8 weeks of yield
  across all three legs simultaneously.
- Wombat impermanent-debt on the single-sided side if USDe weight
  oversaturates the pool (covered cost > emission gain).
- PCS v3 narrow range: a sharp USDe move outside the tick range halts
  emission accrual on that leg.

## TODO
- Resolve real MasterWombat pid for USDe (LOCAL_WOMBAT_PID=30 is placeholder).
- Add USDe peg monitor: pause harvest + exit all three legs if mark
  drifts > 30 bps from $1.
- Implement veWOM boost rebalance: if Wombat changes vote-weighted boost
  schedule, recompute optimal lock size.
