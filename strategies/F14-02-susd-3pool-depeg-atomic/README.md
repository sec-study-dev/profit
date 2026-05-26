# F14-02: sUSD/3pool depeg arb via Synthetix atomic exchange

> Status: **theoretical-historical-replay**. Requires Synthetix atomic exchange
> live for sUSD/sETH at the pinned block. The PoC bails gracefully if the
> mechanism is dormant.

## Mechanism

`sUSD` (Synthetix's native dollar synth) holds its peg through three pressures:

1. **SNX-stakers debt issuance** — minting and burning sUSD via SNX collateral
   on the V2x system.
2. **Curve sUSD 4pool** (`0xA5407eAE9Ba41422680e2e00537571bcC53efBfD`,
   `sUSD/DAI/USDC/USDT`) — the deepest sUSD venue; provides external arbitrage.
3. **Atomic exchange** — anyone holding any other synth can swap it to sUSD at
   the dual-oracle clamped rate. Conversely, sUSD can be swapped to any synth.

When sUSD depegs *down* on Curve (typical pattern: SNX price crashes -> stakers
mint to defend C-ratio -> sUSD over-supply -> Curve weighted toward sUSD), an
arber can:

1. Buy cheap sUSD on Curve (e.g. `DAI -> sUSD` at $0.97).
2. Atomically exchange `sUSD -> sETH` at oracle parity (effectively gets ETH
   exposure at $0.97/$1 of "fair" sUSD value).
3. Sell sETH back to ETH on the Curve sETH/ETH pool.
4. Wrap ETH -> WETH -> swap to USDC on Uniswap -> swap USDC -> DAI on Curve
   3pool, repaying the flashmint.

The opposite leg works when sUSD depegs *up* (rare; historically sUSD has
mostly depegged down).

## Why it composes

This trade chains five primitives Synthetix-flavoured:

1. **Maker DssFlash** (zero-fee, half-billion DAI line) — bootstrap capital.
2. **Curve 3pool** — DAI -> USDC -> ... or directly DAI -> sUSD via 4pool.
3. **Curve sUSD 4pool** — depegged price-discovery leg.
4. **Synthetix atomic exchange** — fair-value exit leg (clamp-priced).
5. **Curve sETH/ETH pool** — converts sETH back to ETH for closure.

The atomic exchange is the *enforcement* leg: it gives the arber an exit at
the Chainlink-anchored "fair" sUSD price even when the open market is offering
$0.97. Synthetix V2x explicitly relies on this arbitrage to defend the peg.

## Preconditions

- Mainnet fork at a block where sUSD is depegged downward in Curve 4pool
  (`get_dy(1, 0, 1e18) > 1.005e18` -> DAI buys >1.005 sUSD per DAI).
- `SystemSettings.atomicExchangeFeeRate(sUSD) > 0` and
  `atomicExchangeFeeRate(sETH) > 0` (both legs of `sUSD -> sETH` must be
  enabled).
- DssFlash with `toll == 0` and sufficient `max`.

## Strategy steps

1. Fork at `FORK_BLOCK = 16_818_900` (SVB weekend, March 2023). On this block
   Curve 4pool had real sUSD depeg pressure as the broader stablecoin panic
   spread; alt-stable depeg arbs were the most reliable on-chain edge of 2023.
2. Quote `get_dy(DAI -> sUSD)` on Curve 4pool for `PROBE = 2_000_000 DAI`. If
   sUSD-out / DAI-in - 1 < 50 bp (cost of round trip), bail with `no_arb`.
3. `DssFlash.flashLoan(this, DAI, PROBE, "")`.
4. In `onFlashLoan`:
   - DAI -> sUSD on Curve 4pool (cheap sUSD).
   - sUSD -> sETH atomic exchange (oracle rate).
   - sETH -> ETH on Curve sETH/ETH pool.
   - ETH -> USDC on Uniswap v3 0.05% pool (or WETH -> USDC then unwrap).
   - USDC -> DAI on Curve 3pool.
   - Repay `PROBE` DAI to DssFlash.
5. Residual DAI is profit.

## PnL math

For an sUSD depeg of `d` basis points down (sUSD trading at `1 - d/10000`):

```
sUSD_out_per_DAI = 1 / (1 - d/10000) * (1 - curve_4pool_slip)
sETH_out_per_sUSD = chainlink_USDperETH^(-1) * (1 - atomic_fee_seth) * (1 - atomic_fee_susd)
ETH_out_per_sETH = (1 - curve_seth_slip)
USDC_out_per_ETH = chainlink_USDperETH * (1 - uni_fee - uni_slip)
DAI_out_per_USDC = (1 - 3pool_slip)
```

Multiplied through, the *Chainlink price drops out* — the trade is purely
`sUSD_depeg_bps - sum_of_AMM_fees - 2 * atomic_fee`. With four 5-bp slippage
legs + 5-bp Uni fee + 2 x 30-bp atomic fee = ~85 bp of cost. Profit edge
opens above 85-bp sUSD depeg, which historically *did* occur (sUSD depegged
to $0.965 on SVB weekend and to ~$0.94 briefly during prior SNX panics).

For a 2M DAI notional at 200-bp depeg (`d = 200`):
- Gross: `2_000_000 * 0.02 = $40_000`
- Costs: `2_000_000 * 0.0085 = $17_000` AMM + atomic fees
- Net: `~$23_000`, less gas (~$50)

## Block pinned

`16_818_900` — Saturday 2023-03-11, SVB weekend. Stablecoin panic propagated
beyond USDC to sUSD, DAI, FRAX, USDD; sUSD traded at a documented 3-4%
discount to par on this day with thin liquidity. Atomic exchange was live and
documented as routing.

If the actual on-fork Curve quote shows < 50 bp depeg (the trade has already
been closed by an arber at this block height), the PoC logs `no_arb` and
exits.

## Risks

- **Atomic exchange disabled or capped** at fork block. Mitigated by
  pre-checking `atomicExchangeFeeRate` and the `atomicMaxVolumePerBlock`
  cap; PoC bails gracefully.
- **Curve sETH/ETH drain.** During Synthetix exits the pool has been near-
  empty multiple times, making the final unwind leg expensive.
- **Direction.** If sUSD depegs *up* (rare), this strategy loses. Production
  would compute both directions; PoC asserts only the dominant down-depeg case.
- **Front-running.** The same arb is well-known; mempool searchers will close
  it within blocks. PoC assumes private inclusion via builder relay.

## Result
Status: theoretical-historical-replay
Expected PnL: ~(depeg_bps - 85bp) × notional on 2M DAI per event (~$23,000 net at SVB-weekend 200 bp sUSD depeg; no-op below 85 bp)

Captures sUSD depeg via Synthetix's atomic-exchange "fair value" exit ramp.
Net edge = sUSD_depeg_bps - 85 bp. Profitable on SVB-weekend-class events;
PoC tolerates blocks where the depeg has already closed (logs `no_arb`).
