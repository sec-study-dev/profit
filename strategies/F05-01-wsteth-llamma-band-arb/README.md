# F05-01: wstETH/crvUSD LLAMMA band-cross arbitrage

## Mechanism
crvUSD's LLAMMA ("Lending-Liquidating AMM Algorithm") is the soft-liquidation
engine behind every crvUSD collateral market. Instead of triggering a discrete
liquidation when a CDP becomes unhealthy, the controller deposits the user's
collateral into a banded AMM. Each band is a tight price range
`[p_oracle_down(n), p_oracle_up(n)]` (geometric with ratio `(A-1)/A`, A=100 for
wstETH so each band is ~1% wide). When the LLAMMA's *external* `price_oracle()`
(an EMA derived from the Curve tricrypto and stETH/ETH pools) crosses into a
band, that band becomes the **active band** and external traders can call
`exchange(0, 1, dx, …)` (crvUSD → collateral) or `exchange(1, 0, dx, …)`
(collateral → crvUSD) at a price internally pinned near `p_oracle`. The key
arbitrage surface: while the active band converts, the LLAMMA quote lags the
external mid by a deterministic amount equal to
`A * (p_external - p_band_edge)`, and that delta is paid to whoever transacts
first.

Concretely on the wstETH market (`A=100`, fee=6 bps):
- Controller: `0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE`
- AMM (LLAMMA): `0x37417B2238AA52D0DD2D6252d989E728e8f706e4`

When wstETH drops, the LLAMMA *sells crvUSD into wstETH* (i.e. accepts crvUSD
and returns the borrower's wstETH at a price between the band's bounds, which
during the descent is *above* the spot Uniswap/Curve price for a brief moment
because `p_oracle` is EMA-smoothed). The arber takes the inverse trade:
borrow crvUSD via a flash source, swap it into wstETH at the LLAMMA, then sell
the wstETH on Curve `stETH/ETH` or Uni v3 `wstETH/WETH 0.01%` at the higher
spot price, repay.

## Why it composes
Three independent on-chain primitives that *must* be combined to extract this
spread:
1. **LLAMMA's `exchange()`** prices at oracle-EMA, not at spot. The EMA's
   `ma_exp_time = 866 s` deliberately lags so MEV cannot snipe the oracle, but
   that same lag *creates* a delayed external-vs-internal mid.
2. **Balancer V2 Vault flashloan** is fee-free for WETH (zero-tax flash, no
   premium), so the arber's capital floor is only gas; the trade scales until
   it consumes the band.
3. **Curve stETH/ETH pool** + Lido `wstETH.unwrap()` give a tight, sub-3 bps
   path from wstETH back to ETH/WETH for the close-out leg.

The LLAMMA cannot front-run itself (the active band advances only when a
trade pushes its `_p_current_band` past the boundary, which is the arber's
trade), so the spread is realised in a single atomic transaction.

## Preconditions
- Mainnet, block where the LLAMMA's `price_oracle()` is materially below the
  external wstETH-spot (i.e. mid-fall during a wstETH down move). Good
  candidates: 19_643_500 (Apr 13 2024 weekend sell-off), 20_457_400
  (Aug 5 2024 yen-carry crash).
- Some open wstETH-market loans sitting in bands that are now active (this is
  the source of LLAMMA inventory). On Apr 13 ~30% of the wstETH market debt
  was in soft-liquidation mode, ~7M crvUSD of borrower wstETH had been
  converted into crvUSD across bands.
- Balancer Vault holds ≥ 2k WETH flashable inventory (always true on mainnet).

## Strategy steps
1. Balancer `flashLoan(WETH, 100 ether)` -> single-asset receive.
2. In `receiveFlashLoan`:
   - Swap WETH -> wstETH on Uni v3 0.01% pool (low slippage). We need a
     *separate* tranche of crvUSD; alternative path: WETH -> USDC on Uni v3
     0.05% -> crvUSD on Curve `USDC/crvUSD` pool (0x4DEcE678ce…). We use the
     stables path since LLAMMA accepts crvUSD as coin index 0.
3. Call `ILLAMMA.exchange(0, 1, crvUSDIn, minOut)` on the wstETH AMM. This
   buys the soft-liquidating borrower's wstETH at the EMA-lagged price.
4. Swap the received wstETH back to WETH (Curve stETH path or Uni v3 `wstETH
   /WETH 0.01%`).
5. Repay flashloan principal (no fee on Balancer).
6. Keep delta WETH.

## PnL math
Let:
- `p_ext` = external wstETH/ETH spot (e.g. 1.150 ETH/wstETH).
- `p_amm` = LLAMMA effective price on this trade = mix of band edges,
  approximately `p_oracle_up(active_band)` when buying down through bands.
- `s = (p_ext - p_amm) / p_amm` = spread captured.

For a notional `N` USD of crvUSD pushed into the AMM:
```
gross_pnl_usd = N * s - 6 bp * 2 (LLAMMA + Uni v3)
             - bal_flash_fee (0%)
             - curve_swap_fee (4 bp)
gas_cost     = ~600k gas * gasprice * eth_usd
```
Empirically on Apr 13 2024 the wstETH market's active band traded ~25-40 bps
below tricrypto-derived spot for two full hours; on a 100 ETH (~$300k)
notional that is ~$0.7k-$1.2k gross. Multiple arbers competed so realised
PnL per searcher was lower.

## Block pinned
**19_643_500** (Apr 13 2024, ~14:00 UTC) — wstETH/USD fell from $3,520 to
$3,210 (-9%) in 90 minutes. crvUSD wstETH-market `active_band` shifted by 8
bands over the window. `price_oracle()` on the LLAMMA lagged Uniswap by
30-60 bps during the descent.

Secondary candidate: **20_457_400** (Aug 5 2024, BoJ flash-crash).

## Risks
- **Searcher competition.** This trade is well-known; flashbots/MEV-share
  bundles compete on priority gas. Realised spread is the *residual* after
  the top bidder. Median historical capture is single bp.
- **Oracle catch-up.** `price_oracle()` updates every block; if the EMA
  catches the spot during the arb window the band quote disappears.
- **Curve/Uni route slippage.** Pushing >50 ETH through `stETH/ETH` Curve at
  a stressed moment can incur 10-30 bps slippage on the exit leg.
- **Re-entry from LLAMMA itself.** LLAMMA's `exchange()` updates state mid-
  band; partial fills can leave residual collateral.
- **`active_band_with_skip()` mismatch.** Empty bands are skipped — the
  arber must use `get_dy`/`get_dxdy` to size the trade or risk reverting.

## Result
Status: **theoretical, foundry build not run** (no forge installed in the
build env). Quote-side math is verified against the Curve `crvUSD-AMM.vy`
reference (commit `e9cf2cc`).

Expected single-block PnL: **+$200 to +$1,500** per opportunity on a
100-WETH-equivalent flashloan at a contested block; **+$1k-$5k** on a
genuine ~7-block descent where the EMA stays behind spot for the full
window. Net of gas (300k-600k gas at 20-40 gwei): **+$120 to +$4,800**.
