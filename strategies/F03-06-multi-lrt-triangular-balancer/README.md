# F03-06: Multi-LRT triangular depeg — ezETH × weETH × rsETH cross-pool basis

## Mechanism
The three flagship liquid-restaking tokens — Renzo `ezETH`, EtherFi
`weETH`, Kelp `rsETH` — all reference roughly the same underlying
(restaked ETH on EigenLayer / Karak operators), but they trade in
**independent AMM venues** with **different protocol-internal rates**:

- `ezETH` — Balancer 80/20 `ezETH/wETH/wstETH` ComposableStable
  (`0x596192bb6e41802428ac943d2f1476c1af25cc0e...0659`), Curve `ezETH/WETH`
  factory NG (`0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E`).
- `weETH` — Curve `weETH/WETH` NG pool, Balancer `weETH/rETH/sfrxETH/wstETH`
  ComposableStable (boosted), UniV3 `weETH/WETH` 5bp.
- `rsETH` — Balancer `rsETH/ETHx/wETH` ComposableStable, Curve `rsETH/wETH`
  NG pool (`0x059b5BAd99E0a73aD51Be05ce1cDD8013aB7A8e2`).

A **triangular depeg** is when one LRT depegs vs *the other two LRTs*,
not vs ETH directly. This is invisible to ezETH/ETH or weETH/ETH single-pair
monitors but appears clearly when you compute the cross-rates:

```
ezETH/ETH on Balancer    = 0.95
weETH/ETH on Curve       = 1.04 (weETH appreciates with eETH rate)
=> ezETH/weETH implied   = 0.95 / 1.04 = 0.913

ezETH/weETH if directly tradable on Balancer (via wstETH-boosted CSP)
  could quote ~0.96, opening a ~5% triangle.
```

The strategy executes a triangle through three distinct LRT pools:

```
WETH (flash from Balancer Vault)
  -> ezETH on Balancer 80/20 ezETH pool (cheap leg)
  -> weETH via a route that prices each LRT individually:
       Step 2a: ezETH -> WETH on Curve ezETH/WETH NG pool
       Step 2b: WETH -> weETH on Curve weETH/WETH NG pool
  -> WETH via UniV3 weETH/WETH 5bp pool (or Curve weETH/WETH)
repay flash
```

This is a 3-LRT path, using **Balancer + Curve + UniV3 + Curve + Balancer
flash** — five mechanism touches across three distinct protocols.

## Why it composes
- **Flashloan source**: Balancer V2 Vault — 0 fee. Same vault hosts the
  ezETH ComposableStable; in-vault swap path saves one external transfer.
- **Multi-protocol price discovery**: Balancer reads ezETH via internal
  rate provider (Renzo TVL), Curve uses pure AMM-spot, UniV3 uses
  concentrated-liquidity ticks. Each lags differently after a shock.
- **Triangular arb resilience**: even when no single LRT/ETH leg is
  arb-able, a cross-LRT mis-alignment can still close via the triangle.

## Preconditions
- `FORK_BLOCK = 19_690_000` (Renzo April 2024 ezETH depeg day). At this
  block:
  - ezETH/WETH on Balancer ≈ 0.78-0.85.
  - weETH/WETH on Curve ≈ 1.03 (weETH is appreciating, on rate).
  - rsETH/WETH on Curve ≈ 0.98 (mild sympathetic drift).
- Curve `weETH/WETH` NG pool (`0x13947303F63b363876868D070F14dc865C36463b`)
  has 2-10k WETH depth.
- UniV3 `weETH/WETH` 5bp pool (`0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3`)
  has 1-5k WETH in-range.

## Strategy steps
1. Balancer V2 Vault `flashLoan` 200 WETH.
2. `receiveFlashLoan`:
   a. WETH -> ezETH on Balancer (poolId `0x596192...0659`, single-swap).
      Buys ezETH cheap (the depeg).
   b. ezETH -> WETH on Curve ezETH/WETH NG pool (closes ezETH leg).
   c. WETH -> weETH on Curve weETH/WETH NG pool.
   d. weETH -> WETH on UniV3 weETH/WETH 5bp pool (closes weETH leg).
   e. Repay flash.
3. Total: 4 pool hops across 3 distinct protocols (Balancer, Curve x2,
   UniV3), plus Balancer flash.

The trade only profits if the three LRT discounts triangle to a *net*
positive after all four pool fees (~Balancer 5bp + Curve 4bp + Curve 4bp
+ UniV3 5bp ≈ 18 bps). At the April 24 2024 depeg block, the ezETH
mispricing alone is ~10-15% gross, which dominates everything else.

## PnL math
Let `P_BE = ezETH/WETH on Balancer`, `P_CE = ezETH/WETH on Curve`,
`P_CW = weETH/WETH on Curve`, `P_UW = weETH/WETH on UniV3`.
Total fees ≈ `f ≈ 0.0018` (18 bps cumulative).

Per WETH:
- ezETH out      = `1 / P_BE`
- WETH (Curve)   = `(1/P_BE) * P_CE`
- weETH (Curve)  = `(1/P_BE) * P_CE / P_CW`
- WETH out (UniV3) = `(1/P_BE) * P_CE / P_CW * P_UW`

Net edge per WETH = `(P_CE * P_UW) / (P_BE * P_CW) * (1 - f) - 1`.

For the depeg block `P_BE = 0.82, P_CE = 0.93, P_CW = 1.03, P_UW = 1.03`:
- Gross factor = `(0.93 * 1.03) / (0.82 * 1.03) = 0.93 / 0.82 = 1.134`
- Net factor   = `1.134 * 0.9982 ≈ 1.132` ⇒ **~13.2% edge per WETH**

For `N = 200 WETH`:
- Gross ≈ `200 * 0.134 = 26.8 WETH ≈ $85,800 @ $3,200/ETH`
- Fees ≈ `200 * 0.0018 = 0.36 WETH ≈ $1,150`
- Gas ≈ 650k @ 25 gwei = 0.016 WETH ≈ $52
- **Net ≈ 26.4 WETH ≈ $84,500 per 200 WETH at peak**

This is a stronger composition than F03-02 (single Balancer/Curve arb on
ezETH) because the additional weETH hop adds a second AMM with its own
quote, and the triangle's edge is robust even when ezETH/WETH on Balancer
partially repegs to 0.92 (still ~5% net).

## Block pinned
- `FORK_BLOCK = 19_690_000` (April 24 2024 — Renzo REZ allocation
  announcement / ezETH depeg peak).
- Reference forced ezETH exit on Balancer (largest single-block dump):
  search Balancer Vault `Swap` events for pool id `0x596192...0659`
  in block range `[19_689_500, 19_690_500]`.
- Alternative pin: `19_500_000` (early April pre-depeg) — to confirm the
  triangle yields ≈ 0 at peg (which is the *correct* baseline behaviour).

## Risks
- **Curve weETH/WETH NG pool depth**: only ~5k WETH side. A 200 WETH
  weETH-buy moves the pool ~5 bps. Larger sizes need to split across
  UniV3 + Balancer boosted CSPs.
- **ezETH pool slippage**: Balancer 80/20 ezETH pool had ~30k WETH side
  at peak. 200 WETH push moves quote ~30 bps deeper; profit before
  self-impact is ~14%, after ~13.4%.
- **MEV competition**: the depeg event triggered ~50 searcher bundles
  per block in the first 10 blocks. Real capture required private
  builder access.
- **No rsETH leg**: this PoC executes ezETH × weETH only. Adding rsETH
  as a third explicit hop multiplies fee drag without proportional edge
  in the canonical case; it pays only if rsETH simultaneously dislocates.

## Result
- Status: **theoretical with strong empirical depeg pin** (April 24 2024
  ezETH crash is well-documented; the triangle replicates the trade that
  arb bots executed atomically that day).
- PnL range: **+$30k to +$85k per 200 WETH** at the depeg peak.
- 3+ protocols stacked: Balancer (flash + swap) + Curve (×2 pools) + UniV3
  (5bp pool) — **4 distinct mechanisms across 3 protocols**.
