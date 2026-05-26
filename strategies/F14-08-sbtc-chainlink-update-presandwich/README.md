# F14-08: sBTC pre-Chainlink-update sandwich (BTC oracle variant)

> Status: **theoretical-historical-replay**. Two-mechanism PoC. BTC-side
> counterpart to F14-04 (which targets ETH/USD). Both rely on the same
> "atomic exchange locks the stale Chainlink price" mechanic but use
> different oracle feeds + different unwind routes.

## Mechanism count: 2

1. **Synthetix V2x atomic exchange** — `exchangeAtomically(sUSD, sBTC)`. The
   atomic exchanger reads min/max of Chainlink BTC/USD and a Curve-based TWAP;
   when the Chainlink feed is stale (close to next heartbeat), the clamped
   price is locked at the *old* value while the open market has moved.
2. **Curve sBTC tri-pool** — `0x7fC77b5c7614E1533320Ea6DDc2Eb61fa00A9714`
   provides the sBTC -> WBTC exit at peg-stable parity. This is the
   "settles-at-spot" leg that contrasts with the atomic's "settles-at-CL" leg.

Uni v3 (WBTC -> WETH and WETH -> USDC) and Curve 4pool (USDC -> sUSD) are
settle-back conveniences, not the priced mechanisms.

## Why a separate BTC variant

BTC/USD on Chainlink has a different update cadence than ETH/USD (BTC has
historically been a 0.5% deviation + 1h heartbeat feed; ETH has been more
frequently nudged). A pre-update sandwich targeting BTC therefore presents:

- Different "edge window" timing — BTC moves of ≥ 0.5% in <1h are common in
  volatile regimes and each triggers exactly one CL push.
- Different atomic-fee gates (`atomicExchangeFeeRate(sBTC)` independent of
  `sETH`).
- Different Curve unwind pool (sBTC tri-pool vs sETH/ETH pool) — these have
  *very* different liquidity profiles, so the realized PnL distribution is
  uncorrelated with F14-04.

## Strategy

1. Fork at `17_300_000` (heuristic mid-2023 block; Wave 5 should sweep blocks
   immediately before known BTC/USD CL pushes for higher-edge entries).
2. Log Chainlink BTC/USD round + staleness — research output.
3. Gate on Synthetix proxy resolution + atomic fee non-zero for sBTC and sUSD.
4. Fund 300k sUSD (`deal()` works on V2x sUSD).
5. Execute the round trip:
   - sUSD -> sBTC via atomic exchange (locks pre-update Chainlink BTC price).
   - sBTC -> WBTC via Curve sBTC tri-pool (peg-stable).
   - WBTC -> WETH via Uni v3 0.3%.
   - WETH -> USDC via Uni v3 0.05%.
   - USDC -> sUSD via Curve sUSD 4pool.
6. Log realized delta `susdBack - 300_000e18`.

## Preconditions (availability gate)

- `getAddress("Synthetix") != 0`.
- `atomicExchangeFeeRate(sBTC) > 0` and `atomicExchangeFeeRate(sUSD) > 0`.
- Curve sBTC tri-pool has both sBTC and WBTC > 50 BTC.

If any gate fails the PoC logs the failure mode and returns; PnL report
remains honest.

## PnL math

For BTC drift `d` bps between Chainlink-locked-price and post-update market:

```
sBTC_out = PROBE_SUSD * (1 + d/10_000 - f_atom_sUSD - f_atom_sBTC) / BTCUSD
WBTC_out = sBTC_out * (1 - f_curve_sbtc)
WETH_out = WBTC_out * BTCUSD/ETHUSD * (1 - f_uni3 - f_slip)
USDC_out = WETH_out * ETHUSD/USDCUSD * (1 - f_uni05 - f_slip)
sUSD_back = USDC_out * (1 - f_4pool)
delta_bps = d - (f_atom_sUSD + f_atom_sBTC + f_curve_sbtc + f_uni3 + f_uni05 + f_4pool)
           = d - ~85 bp
```

So `delta_bps > 0` iff CL BTC was stale by > 85 bp at the entry block.

For 300k sUSD at `d = 150 bp`:
- Gross: $4,500
- Costs: ~$2,550
- Net: ~$1,950 before gas

## Block pinned

`17_300_000` — mid-2023. Atomic active for sBTC + sUSD; Curve sBTC pool
liquid; chosen heuristically pending a Wave 5 update-block sweep.

## Risks

- **Atomic disabled / capped.** Standard gate; PoC bails.
- **Direction.** Pre-update sandwich is direction-sensitive — buying sBTC
  before a *down*-update and selling after = loss. The 2-mechanism PoC
  always does sUSD->sBTC->...->sUSD; in production a runner would also
  evaluate the inverse (sUSD->sBTC at "fair" and unwinding at CL-supported
  high after up-update).
- **CL feed staleness can't be predicted** in a backtest fork; expected
  realized PnL across random blocks is ≤ 0. PoC therefore documents the
  distribution rather than asserting profit — failure-tolerant.

## Result
Status: theoretical-historical-replay
Expected PnL: ~(BTC_drift_bps - 85bp) × notional on 300k sUSD per event (~$1,950 net at 150 bp pre-update CL BTC staleness; expected realized PnL ≤ 0 across random blocks)

Two-mechanism BTC counterpart to F14-04. Condition-dependent PnL —
profitable only on blocks where the Chainlink BTC/USD aggregator is near its
heartbeat boundary at fork-block timestamp. Honest no-arb logging on median
blocks; PoC structure remains a research probe.
