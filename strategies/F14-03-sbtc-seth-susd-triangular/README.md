# F14-03: sBTC <-> sETH <-> sUSD synth triangular arbitrage

> Status: **theoretical-historical-replay**. Requires Synthetix atomic exchange
> live for sBTC, sETH, and sUSD at the pinned block. The PoC bails gracefully
> if any leg is dormant.

## Mechanism

Synthetix V2x exposes one `exchangeAtomically(srcKey, amt, dstKey, ...)` entry
point. It looks up the **source** and **destination** prices from the dual
oracle (Chainlink ⊓ Curve TWAP) and converts atomically at the inferred USD
rate. The arithmetic is:

```
amountReceived_dest
  = sourceAmount * effectivePriceUSD(srcKey) / effectivePriceUSD(dstKey)
    * (1 - atomicExchangeFeeRate(srcKey))
    * (1 - atomicExchangeFeeRate(dstKey))
```

Each synth's `effectivePriceUSD` is computed independently. When three synths
are involved, three independent Chainlink feeds (ETH/USD, BTC/USD, and the
sUSD peg = $1) are read. **If any single feed is stale or just stepped on a
new Chainlink round**, the synth's `effectivePriceUSD` differs from spot, and
a round-trip `sUSD -> sBTC -> sETH -> sUSD` no longer terminates at the
starting balance: it leaves a residual.

The triangular trade can be expressed as:

```
balance_end = balance_start
              * P_BTC_atomic / P_BTC_atomic                 (BTC cancels)
              * P_ETH_atomic / P_ETH_atomic                 (ETH cancels)
              * (1 - f)^6                                   (6 fee legs)
```

In a perfectly synchronized world, the only term that matters is `(1 - f)^6`
— always negative. The trade is profitable when the *atomic clamp picks
different sides* on different legs. Concretely:

- `sUSD -> sBTC` clamps to `min(Chainlink_BTC, CurveTWAP_BTC)` on the buy.
- `sBTC -> sETH` clamps to `max(Chainlink_BTC, CurveTWAP_BTC)` on the sell of
  BTC, and `min(Chainlink_ETH, CurveTWAP_ETH)` on the buy of ETH.
- `sETH -> sUSD` clamps to `max(Chainlink_ETH, CurveTWAP_ETH)` on the sell.

If `Chainlink_BTC > CurveTWAP_BTC` (Chainlink high) while `Chainlink_ETH <
CurveTWAP_ETH` (Chainlink low), then the BTC leg gets a *favorable* clamp on
the sell and the ETH leg gets a *favorable* clamp on the buy: the trader
captures the spread between the two TWAP-vs-feed deviations, minus six fee
multiplications.

## Why it composes

This trade is **pure synth-internal**: no AMM exit, no flashloan, only an
initial sUSD balance and three atomic exchanges. That makes it:

- **Gas-cheap.** Three calls into the same proxy.
- **MEV-resistant.** No on-chain price-sensitive AMM legs to be sandwiched.
- **Volume-capped, not slippage-capped.** Atomic max-volume-per-block is the
  only constraint; there is no AMM impact term.
- **Self-funded** once you have sUSD (no flashloan callback needed).

## Preconditions

- `SystemSettings.atomicExchangeFeeRate(sBTC)`, `atomicExchangeFeeRate(sETH)`,
  `atomicExchangeFeeRate(sUSD)` all non-zero (means atomic enabled).
- Sufficient `atomicMaxVolumePerBlock` for the probe size.
- The Chainlink BTC/USD and ETH/USD aggregators on the fork block must
  exhibit *opposite-sign* deviation from their Curve TWAPs (the very condition
  that makes the triangle profitable).

## Strategy steps

1. Fork at `FORK_BLOCK = 17_500_000` (June 2023, atomic exchange live).
2. Look up Synthetix proxy via AddressResolver.
3. Fund the contract with `PROBE_SUSD = 500_000 sUSD` (whale prank or
   foundry `deal`).
4. `sUSD -> sBTC` atomically.
5. `sBTC -> sETH` atomically.
6. `sETH -> sUSD` atomically.
7. Compare ending sUSD to starting; positive delta = arbitrage captured.

The PoC computes the round-trip delta and **does not assert profit**: this
strategy is heavily condition-dependent on oracle-vs-TWAP deviation. Instead
it emits a log line so Wave 3 can survey across blocks to find profitable
windows.

## PnL math

```
sUSD_end = PROBE
         * (P_BTC^buy_clamp / P_BTC^sell_clamp)
         * (P_ETH^sell_clamp / P_ETH^buy_clamp)
         * (1 - f_sUSD) (1 - f_sBTC)  -- leg 1
         * (1 - f_sBTC) (1 - f_sETH)  -- leg 2
         * (1 - f_sETH) (1 - f_sUSD)  -- leg 3
```

With historic atomic fees of `30bp` on majors and `5bp` on sUSD:
- six-fee term: `(0.997)^4 * (0.9995)^2 ≈ 0.987` -> 130 bp of "rent".
- Need clamp spread > 130 bp combined to break even.

In a Chainlink-vs-TWAP study during the late-2022/early-2023 period, the
median absolute deviation between Chainlink BTC/USD and Synthetix's
configured Curve TWAP was ~60 bp; tails ran to >300 bp during fast moves.
The trade is profitable in the tails only.

For `PROBE = 500_000 sUSD` and a 200 bp combined clamp deviation:
- Gross: `500_000 * 0.02 = $10_000`
- Rent:  `500_000 * 0.013 = $6_500`
- Net:   `~$3_500`

## Block pinned

`17_500_000` — June 2023. Atomic exchange live for sBTC, sETH, sUSD;
sufficient liquidity per Synthetix dashboards of the era.

## Risks

- **Most blocks have no edge.** Combined fee load is 130 bp; trade only works
  in oracle-update tails. PoC logs delta instead of asserting.
- **Atomic disabled for one of the three keys.** PoC pre-checks and exits.
- **Volume cap.** `atomicMaxVolumePerBlock` is shared across all atomic
  exchanges in a block; a competing arber may have consumed it earlier in
  the same block.
- **sBTC liquidity.** sBTC's atomic backing was thinner than sETH's; the
  exchanger may revert with `ATOMIC_MAX_VOLUME_EXCEEDED` for non-trivial
  sizes.

## Result
Status: theoretical-historical-replay
Expected PnL: ~(clamp_spread_bps - 130bp) × notional on 500k sUSD per event (~$3,500 net at 200 bp combined clamp deviation; profitable only in oracle-update tails)

Pure-synth triangular probe of Synthetix's dual-oracle clamp. PoC samples the
delta and surfaces it for Wave 3 cross-block sweeps; profitability requires
combined clamp deviation > ~130 bp, which occurs only in oracle-update tails.
