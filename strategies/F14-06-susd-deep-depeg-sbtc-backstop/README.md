# F14-06: sUSD deep-depeg sBTC backstop — DssFlash + Synthetix atomic + Curve sBTC

> Status: **theoretical-historical-replay**. Three-mechanism PoC. Requires
> sUSD trading at a >95 bp depeg on Curve 4pool *and* atomic exchange live
> for both `sUSD` and `sBTC`. Gracefully bails otherwise.

## Why this is *different* from F14-02

F14-02 uses the canonical sETH route to exit a depegged sUSD: cheap sUSD ->
atomic to sETH -> Curve sETH/ETH. That exit can be congested:

- Curve sETH/ETH pool routinely depletes during Synthetix exit waves
  (the historical "sUSD-to-ETH" path is the most arbed leg).
- Other Synthetix-aware searchers race the same trade.

F14-06 takes the **sBTC backstop route** — atomic sUSD -> sBTC, then Curve
sBTC/WBTC, then Uni v3 WBTC/WETH/USDC. Three reasons this is its own family
slot rather than a parameter tweak:

1. The exit-side pool is `0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714` (sBTC
   tri-pool) — completely disjoint from F14-02's sETH/ETH pool.
2. The Chainlink oracle being relied on is BTC/USD, not ETH/USD — so the
   atomic clamp prices off a different feed and updates on a different cadence.
3. The trade is only triggered at deeper depegs (95 bp gate, vs F14-02's
   50 bp) since the costs are higher (WBTC unwind has wider Uni v3 spreads
   than USDC/WETH 0.05%).

## Mechanism count: 3

1. **Maker DssFlash** — zero-fee DAI flashmint
   (`0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA`).
2. **Synthetix V2x atomic exchange** — `sUSD -> sBTC` (resolved via
   `AddressResolver(0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83)`).
3. **Curve** — sUSD 4pool (entry), sBTC tri-pool (sBTC -> WBTC exit), and
   3pool (USDC -> DAI to close).

Uniswap v3 is the WBTC -> WETH -> USDC settle-back venue; it is *not* a priced
mechanism (it converts WBTC to a 3pool-eligible token, nothing more).

## Strategy

1. Probe Curve 4pool: how much sUSD does 1.5M DAI buy?
2. If `(sUSD_out / DAI_in - 1) < 95 bp` -> bail (`no_arb`).
3. Gate `atomicExchangeFeeRate(sUSD)` and `atomicExchangeFeeRate(sBTC)`; bail
   if either is 0.
4. `DssFlash.flashLoan(this, DAI, 1_500_000e18)`.
5. In `onFlashLoan`:
   - DAI -> sUSD on Curve 4pool (cheap sUSD).
   - sUSD -> sBTC via atomic exchange (oracle parity).
   - sBTC -> WBTC on Curve sBTC tri-pool.
   - WBTC -> WETH on Uni v3 0.3%.
   - WETH -> USDC on Uni v3 0.05%.
   - USDC -> DAI on Curve 3pool.
   - Repay 1.5M DAI; residual = profit.

## Preconditions (availability gate)

| Gate                                                  | If fails -> |
| ----------------------------------------------------- | ----------- |
| `getAddress("Synthetix") != 0`                        | log + skip  |
| `DssFlash.toll() == 0 && DssFlash.max() >= 1.5M DAI`  | revert      |
| `4pool.get_dy(DAI, sUSD, 1.5M) - 1.5M > 95 bp`        | log + skip  |
| `atomicExchangeFeeRate(sUSD) > 0 && (sBTC) > 0`       | log + skip  |
| Curve sBTC->WBTC swap reverts                         | log + skip  |
| atomic call reverts                                   | unwind + log|

## PnL math

For depeg `d` bps and notional `N` DAI:

```
sUSD_out / DAI_in  = 1 + d/10_000   - f_4pool      (~5 bp)
sBTC_out (fair)    = sUSD_out / BTCUSD * (1 - f_atom_sUSD - f_atom_sBTC)
                                                   (~35 bp combined)
WBTC_out / sBTC    = 1 - f_curve_sbtc              (~10 bp)
WETH_out / WBTC    = (WBTC/USD - f_uni3 - f_slip)  (~25 bp incl slip)
USDC_out / WETH    = WBTC * BTCUSD * (1 - f_uni)   (~10 bp)
DAI_out / USDC     = 1 - f_3pool                   (~3 bp)
```

Multiplied through, BTC price *drops out* — net = `d - sum_fees ≈ d - 95 bp`.

For 1.5M DAI at 200 bp depeg:
- Gross: $30,000
- Costs: ~$14,250
- Net: ~$15,750 before gas

For depeg < 95 bp, the trade is uneconomic on this route (F14-02's sETH route
is cheaper). PoC bails on the gate.

## Block pinned

`16_818_900` — SVB weekend. Stablecoin contagion pulled sUSD off peg to ~94c
briefly. Atomic exchange documented operational.

## Risks

- **sBTC tri-pool imbalance.** If WBTC has been drained from the pool
  (sBTC-heavy state), the `sBTC -> WBTC` leg slips badly. PoC bails.
- **Atomic disabled on either side.** PoC reads `atomicExchangeFeeRate` and
  bails if zero.
- **Direction.** sUSD depeg up loses on this route; not handled.
- **Front-running.** Searchers race sUSD depegs aggressively; production
  must use private inclusion.

## Result
Status: theoretical-historical-replay
Expected PnL: ~(depeg_bps - 95bp) × notional on 1.5M DAI per event (~$15,750 net at SVB-weekend 200 bp sUSD depeg; no-op below 95 bp)

Three-mechanism BTC-side backstop for sUSD deep depeg. Net PnL = `depeg_bps -
95 bp` of notional. Differentiated from F14-02 by relying on a distinct
oracle (BTC/USD) and a disjoint exit pool (Curve sBTC tri-pool); PoC fails
cleanly on shallow depegs and disabled-atomic configurations.
