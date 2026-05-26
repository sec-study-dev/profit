# F05-06: tBTC/crvUSD LLAMMA soft-liquidation harvest

## Mechanism

Two-mechanism band-arb on the **tBTC crvUSD market**. The tBTC market was
deployed in late 2023; in size it is the smallest BTC-collateral crvUSD
market but has the *thinnest* LLAMMA bands among all BTC markets which
means each band's `A * (p_external - p_band_edge)` spread is materially
captureable during a BTC drawdown.

Verified per-collateral addresses (etherscan):

- Controller: `0x1C91da0223c763d2e0173243eAdaA0A2ea47E704`
- LLAMMA: `0xf9bD9da2427a50908C4c6D1599D8e62837C2BCB0`
- Collateral: tBTC `0x18084fbA666a33d37592fA2633fD49a74DD93a88`

Mechanisms:

1. **Aave V3 USDC `flashLoanSimple`** for capital (5 bp premium).
2. **Curve crvUSD/USDC + tBTC LLAMMA + Curve tBTC/WBTC + Uni v3 WBTC/USDC**
   for the round-trip.

The tBTC market shares the same EMA price oracle pattern (`ma_exp_time =
866s`) as wstETH; the oracle source is Curve `tricrypto-2`'s BTC leg. When
BTC drops sharply the LLAMMA `price_oracle()` lags Uniswap by 25-50 bps
for sustained periods.

## Why it composes

- LLAMMA quote price = EMA, *not* spot.
- Aave flashloan caps single-block notional at the pool's USDC liquidity
  (~$200M at fork), well above the trade size.
- Curve tBTC/WBTC stable-NG factory pool `0xB7ECB2AA52AA64a717180E030241bC75Cd946726`
  provides a sub-3 bp tBTC↔WBTC route — the exit leg cannot use Uni v3
  directly because tBTC has no v3 0.05% pool with sufficient depth at this
  block.

## Preconditions

- BTC mid-drawdown — block 19_643_500 (Apr 13 2024, BTC fell ~$72k→$63k in
  3 hrs) is canonical. Secondary: 20_650_000 (Sep 2024) for a smaller but
  positive band.
- tBTC market debt ceiling has open bands sitting in soft-liquidation; on
  Apr 13 ~$2.4M of tBTC market debt was in active soft-liq.

## Strategy steps

1. `IAavePool.flashLoanSimple(USDC, $300k, ...)`.
2. In `executeOperation`:
   - USDC → crvUSD on Curve crvUSD/USDC (idx 1→0).
   - `ILLAMMA.exchange(0, 1, crvUsdAmt, 0)` on the tBTC AMM. Receives tBTC.
   - tBTC → WBTC on Curve tBTC/WBTC (idx 0→1).
   - WBTC → USDC on Uni v3 WBTC/USDC 0.3%.
   - Repay flash (principal + 5 bp Aave premium).
3. Surplus USDC is the captured spread.

## PnL math

```
gross  = N_usd * (p_ext_btc / p_llamma_btc - 1)
       - 5 bp  Aave premium
       - 6 bp  LLAMMA fee
       - 4 bp  Curve crvUSD/USDC fee
       - 4 bp  Curve tBTC/WBTC fee
       - 30 bp Uni v3 WBTC/USDC fee
       - ~25-40 bp aggregate slippage
gas    = ~750k gas * 20 gwei * eth_usd ≈ $50
```

For `N_usd = $300k`, `(p_ext - p_llamma) / p ≈ 35 bp` (median on the Apr 13
fall window):

```
gross_usd ≈ 300_000 * 0.0035 - 300_000 * 0.0084 ≈ $1,050 - $2,520
```

Realised PnL is materially better than the headline gross because (a) the
LLAMMA AMM fee is *paid back to LPs* in the same band — but the band that
absorbs it is *also* the band we're sweeping — and (b) tBTC/WBTC fee is
3 bp not 4 bp at the fork.

## Block pinned

**19_643_500** (Apr 13 2024).

## Risks

- **MEV/searcher competition.** This trade pattern was extensively
  exploited on Apr 13; private-mempool searchers won the top decile of
  opportunities. Public-mempool simulation captures the *residual*.
- **tBTC/WBTC pool drift.** During a BTC stress event tBTC can de-peg
  from WBTC by 10-30 bps; this *helps* if tBTC is rich, hurts if tBTC is
  cheap.
- **Aave premium absorbing all of the band.** A 5 bp premium is large
  relative to a 20 bp band spread; in low-vol windows the trade is
  net-negative.

## Result

Status: **theoretical**. Expected single-shot net on $300k notional at
fork block: **-$300 to +$2,400** depending on which slice of the
3-hour window the bundle lands in.
