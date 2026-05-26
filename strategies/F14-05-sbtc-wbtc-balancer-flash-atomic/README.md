# F14-05: sBTC/WBTC drift via Synthetix atomic + Balancer flash + Curve sBTC tri-pool

> Status: **theoretical-historical-replay**. Three-mechanism PoC. Requires
> Synthetix V2x atomic exchange to be live for `sBTC` and `sUSD` and the Curve
> sBTC tri-pool to be liquid at the pin block. The PoC gracefully bails on
> dormant blocks.

## Mechanism count: 3

1. **Synthetix V2x atomic exchange** (`exchangeAtomically` on the proxy looked
   up via `AddressResolver(0x823bE81bbF96BEc0e25CA13170F5AaCb5B79ba83)`).
2. **Balancer V2 Vault flashloan** (`flashLoan` on
   `0xBA12222222228d8Ba445958a75a0704d566BF2C8`, currently zero-fee).
3. **Curve** — both the `sBTC/WBTC/renBTC` tri-pool
   (`0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714`) and the sUSD 4pool
   (`0xA5407eAE9Ba41422680e2e00537571bcC53efBfD`).

Uniswap v3 appears as a settle-back venue (WETH <-> WBTC and USDC <-> WETH) but
is not the *priced-mechanism* — the atomic clamp does the work, and the
Balancer + Curve legs surface the drift.

## Strategy

When the Chainlink BTC/USD aggregator runs at a different speed than the
WBTC market price (e.g. fresh sell-off on BTC perp / spot venues hasn't yet
propagated to the on-chain CL feed):

1. Balancer flash 200 WETH.
2. WETH -> WBTC via Uni v3 0.3%.
3. WBTC -> sBTC via Curve sBTC tri-pool (1 WBTC -> ~1 sBTC, peg-stable).
4. **sBTC -> sUSD via Synthetix atomic exchange** — settles at the dual-clamp
   Chainlink-bounded rate (the "fair value" exit).
5. sUSD -> USDC via Curve sUSD 4pool.
6. USDC -> WETH via Uni v3 0.05%.
7. Repay 200 WETH; residual = profit.

The atomic leg is the *only* leg that prices off Chainlink — the other five
legs price off open-market AMM curves. When CL BTC trails market by `d` bps,
this round-trip clears `d * notional - costs`.

## Why three mechanisms

Each of Synthetix / Balancer / Curve is independently necessary:

- **Without Synthetix atomic exchange**, the sBTC <-> sUSD conversion has to
  go through Curve sBTC/WBTC then Uni WBTC/USDC, which prices off market — no
  oracle clamp, no edge.
- **Without Balancer flash**, the strategy is capital-bound; Curve sBTC tri-
  pool is too shallow to ride a meaningful BTC drift with own capital, and
  Maker DssFlash (DAI-only) doesn't help when the inventory side is WETH.
- **Without Curve sBTC tri-pool**, there's no direct WBTC -> sBTC peg-stable
  ramp; Uni v3 doesn't have a deep WBTC/sBTC market.

## Preconditions

- `AddressResolver.getAddress("Synthetix")` resolves.
- `SystemSettings.atomicExchangeFeeRate(sBTC) > 0` and
  `atomicExchangeFeeRate(sUSD) > 0`.
- Curve sBTC tri-pool has WBTC and sBTC balances both > 50 BTC.
- Balancer Vault flash fee == 0 for WETH (current governance).

## Preconditions (availability gate)

If any precondition fails, the PoC logs the failure mode and returns rather
than asserting. This preserves the test as a research probe.

## PnL math

For notional `N` WETH and BTC drift `d` bps:

```
PnL_WETH / N ≈ d/10_000
              - f_uni_wbtc        (~25 bp incl. slip)
              - f_curve_sbtc      (~10 bp incl. slip)
              - f_atom_sBTC       (~30 bp)
              - f_atom_sUSD       (~5 bp)
              - f_curve_susd      (~5 bp)
              - f_uni_usdc        (~10 bp)
              - f_balancer_flash  (0 at current parameters)
```

Total cost: ~85 bp. Profitable iff BTC CL-vs-market drift exceeds ~85 bp;
historically observed on BTC fast moves > $500 in seconds.

For 200 WETH (~$380k at $1,900/ETH) and `d = 150 bp`:
- Gross: $5,700
- Costs: ~$3,200
- Net: ~$2,500 before gas

For `d` below 85 bp the PoC logs a loss; the test does not assert profit so
the no-arb path remains a clean research probe.

## Block pinned

`17_500_000` — mid-2023. Chosen because:

- Atomic exchange documented operational for sBTC + sUSD.
- Curve sBTC tri-pool had >100 BTC TVL.
- Uni v3 WETH/WBTC 0.3% pool had >$50M TVL.

## Risks

- **Atomic disabled.** Governance frequently tightens atomic-eligible synths;
  PoC gates on the fee read.
- **sBTC liquidity in Curve sBTC tri-pool.** Multiple historical depletion
  events. PoC bails if the trade reverts.
- **Direction risk.** BTC drift can go either way — production must implement
  the mirror trade (`USDC -> sUSD -> sBTC -> WBTC -> WETH`).
- **Volume cap.** `atomicMaxVolumePerBlock` is in sUSD; PoC inventory ~$380k
  fits historical caps but spot-check at fork block.

## Result
Status: theoretical-historical-replay
Expected PnL: ~(|BTC_drift_bps| - 85bp) × notional on 200 WETH per event (~$2,500 net at 150 bp BTC CL-vs-market drift on ~$380k notional; no-op below 85 bp)

Three-mechanism BTC-flavoured atomic arb. Profitable iff |Chainlink_BTC_drift|
> 85 bp; PoC gracefully bails below that or when atomic is disabled.
