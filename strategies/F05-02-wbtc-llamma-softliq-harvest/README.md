# F05-02: WBTC/crvUSD LLAMMA soft-liquidation harvest

## Mechanism
The crvUSD WBTC market mirrors the wstETH market but with `A=100`, fee=6 bps,
and a BTC-denominated oracle EMA derived from Curve `tricryptoUSDC`,
`tricryptoUSDT`, and `tricryptoFRAX`. The collateral is regular WBTC
(`0x2260FAC...`).

Verified addresses (etherscan):
- WBTC Controller: `0x4e59541306910aD6dC1daC0AC9dFB29bD9F15c67`
- WBTC LLAMMA:     `0xE0438Eb3703bF871E31Ce639bd351109c88666ea`

Unlike wstETH which has an ever-appreciating stake rate, WBTC has *zero*
internal accrual — so the LLAMMA's `price_oracle` lag is purely a function of
the BTC/USD-USD-stable EMA. When BTC dumps, the LLAMMA quote (used by the
banded AMM during the descent) stays above tricrypto spot for ~5-10 blocks.

The arbitrage surface is identical in structure to F05-01 (band-stale quote)
but with a **larger** capacity because WBTC is the highest-notional crvUSD
market (was >$120M debt at peak). The trade-off: WBTC has materially worse
secondary liquidity than wstETH, so the close-out leg slippage dominates.

## Why it composes
1. **LLAMMA's banded quote** during a BTC down move sells WBTC at price
   between `p_oracle_up(active_band)` and `p_oracle_down(active_band)`, both
   of which are EMA-lagged.
2. **Aave v3 flashloan** in USDC (60 bps flash fee historically, 5 bps post
   AIP-381) gives the arber access to ~$200M of one-shot crvUSD-quoted
   capital after the USDC->crvUSD hop.
3. **Uni v3 `WBTC/USDC 0.3%`** pool is the deepest spot route to unwind WBTC
   after taking it out of the LLAMMA; combined with the `WBTC/WETH 0.3%`
   pool for a triangular exit when WBTC/USDC depth is degraded.

The composition is non-trivial because Aave's USDC flashloan fee plus the
USDC -> crvUSD Curve fee (1 bp) must each be *smaller* than the captured
spread; on contested blocks this isn't true, which is why this trade isn't
constantly profitable.

## Preconditions
- Mainnet, block during a sharp BTC sell-off where the LLAMMA's oracle
  trails tricrypto by ≥ 30 bps. Empirically: Apr 13 2024, Aug 5 2024,
  Mar 5 2024 (BTC ATH double-rejection).
- WBTC market has active borrowers with collateral in soft-liq bands. The
  WBTC market lit up in earnest in early 2024; by Apr ≥ $80M debt.
- Aave v3 USDC supply utilisation < 100% (always true).

## Strategy steps
1. Aave v3 `flashLoanSimple(USDC, 250_000e6)` (or Balancer Vault `flashLoan`
   if WETH-denominated is cheaper).
2. Inside callback:
   a. USDC -> crvUSD on Curve (Curve `USDC/crvUSD` pool, 1 bp).
   b. `ILLAMMA(LLAMMA_WBTC).exchange(0, 1, crvUSDIn, minOut)` — receive WBTC
      from the soft-liquidating band.
   c. WBTC -> USDC on Uni v3 0.3% (or WBTC -> WETH -> USDC if shallow).
   d. Repay Aave principal + 5 bp fee.
3. Keep delta USDC. Slippage on (c) determines whether the trade clears.

## PnL math
Variables:
- `N` = USDC notional in the flashloan (e.g. 250_000e6 = $250k).
- `s_amm` = LLAMMA spread vs Uni-v3 WBTC/USDC mid (bp).
- `f_aave` = 5 bp (Aave V3 flashLoanSimple).
- `f_curve` = 1 bp (USDC/crvUSD Curve stableswap-NG).
- `f_amm` = 6 bp (LLAMMA fee).
- `slip_uni` = 5-25 bp on the WBTC -> USDC unwind for $250k.

```
gross_usd = N * s_amm * 1e-4
fees_usd  = N * (f_aave + f_curve + f_amm + slip_uni) * 1e-4
net_usd   = gross_usd - fees_usd - gas_usd
```

For a 30 bp captured spread, `gross = $750`, `fees ≈ $42 + $13 + $15 + $30 =
$100`, gas ~$15 -> **net ≈ $635** per opportunity. On Apr 13 the spread
opened to 50-90 bp briefly, but only the first searcher captured it.

## Block pinned
**19_643_500** (Apr 13 2024) — same down-move as F05-01, but the BTC leg
trailed by ~2 bands additionally because BTC pulled 12% in 6 hours.
Secondary candidate: **20_457_300** (Aug 5 2024 BoJ crash, BTC -8% in 4h).

## Risks
- **Searcher MEV competition.** The largest crvUSD market is heavily watched
  by Flashbots searchers; ≥ 70% of opportunities clear in block-0.
- **WBTC depeg.** WBTC was discounted ~80 bp during the BiT Global custodian
  uncertainty in Aug 2024; the close-out leg loses if WBTC spot diverges
  from BTC oracle.
- **Active-band skip.** `active_band_with_skip()` may bypass empty bands,
  making the captured spread smaller than the apparent oracle lag.
- **Aave premium hike.** Aave governance can raise `FLASHLOAN_PREMIUM_TOTAL`
  to 9 bps, which would eat most of the captured spread.
- **Curve crvUSD/USDC pool slippage.** At very large flashloan size (>1M
  crvUSD) the slippage on the USDC->crvUSD swap exceeds the spread.

## Result
Status: **theoretical, foundry build not run**. Expected per-block
opportunity PnL on a $250k notional at a contested block: **+$150 to
+$1,200** net. At an uncontested mid-fall block: **+$1k-$4k**. Annualised
TVL-weighted EV across all WBTC market hot days in 2024: ~$25k-$70k for
a sole searcher.
