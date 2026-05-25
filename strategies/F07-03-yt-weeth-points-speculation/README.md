# F07-03: YT-weETH point speculation

## Mechanism
Pendle's YT (Yield Token) is the *all-yield* leg complementary to PT. Every
unit of underlying SY accrues yield + reward streams to the YT holder
until maturity, after which YT is worthless. Crucially for restaking, "yield"
on SY-weETH includes the off-chain **EtherFi loyalty points** and the
**EigenLayer restaking points** that flow through the wrapper — and Pendle
explicitly streams those through to YT holders by being recognised by EtherFi
/ EigenLayer as a points-eligible address (with a per-cycle multiplier deal).

The economics: $1 of YT-weETH controls roughly $30-50 of "yield notional"
because YT is priced as `(implied_yield_value_to_maturity)` rather than at
face. So YT-weETH at a $0.025/weETH-notional price is effectively a
**~40× point levered claim** on EtherFi+EigenLayer rewards over the
remaining maturity. If you believe the off-chain points will TGE at a
USD value greater than the implied yield baked into YT spot, YT longs are
positive-EV; if not, YT decays to zero and you lose the premium.

The unique compositional element: YT actually subsidises a point-speculator
by *paying you the eETH-staking yield* on the underlying notional in
addition to streaming points. Some YT-weETH series carry an explicit
"Pendle x EtherFi" multiplier bonus (e.g., 1.5×-2× points vs holding eETH
directly).

## Why it composes
This is one of the cleanest examples of a "synthetic warrant" on an
off-chain reward. Pendle's tokenisation forces a market price on the
*present discounted value of all future yield + points* of a yield-bearing
token, which means the YT spot price is the market's collective bet on
TGE values. If the speculator has informational edge on either:
- the points-per-day rate (e.g. via off-chain dashboards)
- the $/point TGE conversion (e.g. via leaked tokenomics)
- the multiplier offered by Pendle vs direct holding

… then YT becomes a focused expression of that view, with up to 40-50×
notional leverage on the underlying yield without any liquidation risk
or borrow cost. The only "leverage cost" is the YT premium itself.

The strategy composes especially well with F02 (LRT looping) for two
reasons. First, a YT-long position is *uncorrelated* with the PT-leg
return, so a balanced PT+YT book gives a "synthetic SY" exposure that
isolates points-vs-implied-yield. Second, Pendle's points multipliers
often EXCEED what direct LRT looping can achieve, so YT can be the most
points-efficient way to express LRT exposure if the YT premium is
modest.

## Preconditions
- Mainnet fork before YT-weETH-26DEC2024 maturity, ideally early in the
  market's lifetime so YT is still cheap relative to the value of
  remaining points.
- Pendle YT-weETH market has buy-side liquidity (verified via
  PendleMarket totalActiveSupply / readState).
- The user has a $/point assumption — this strategy is a directional
  speculation, not a market-neutral carry.

## Strategy steps
1. Acquire WETH equity.
2. Approve Pendle Router.
3. Call `swapExactTokenForYt(market=PT/YT-weETH-26DEC2024)` with all WETH;
   receive a large nominal YT balance (small $/YT × large notional).
4. Hold to maturity (or sell early if YT premium expands).
5. Periodically call `redeemDueInterestAndRewards(user, true, true)` on
   the YT contract to crystallise (a) accrued SY interest and (b) any
   reward tokens streamed through Pendle.
6. At maturity YT expires worthless on chain but the off-chain points have
   already accrued to address(this) on EtherFi+EigenLayer's ledgers; at
   TGE they convert to claimable tokens.

## PnL math (explicitly separates implied APY from points)

Let:
- `Y_buy`       = WETH spent on YT
- `n_YT`        = YT received (high count: roughly `Y_buy / YT_spot_price`)
- `S_notional`  = SY notional controlled by YT ≈ n_YT (1:1 with SY units)
- `r_eEth`      = SY-implied (eETH) staking APY ≈ 3.0% on S_notional
- `t`           = years to maturity = 0.493 (Aug 15 → Dec 26)
- `mult_EF`     = EtherFi multiplier on Pendle (assume 2×)
- `mult_EL`     = EigenLayer multiplier (assume 2×, season 2-3 conventions)
- `pts_rate`    = baseline EtherFi points / weETH / day ≈ 5,000
- `usd_per_pt`  = ASSUMED TGE value per EtherFi point in USD = $0.001
                  (assumption — explicitly stated; range observed in
                  similar TGEs: $0.0005-$0.002)
- `usd_per_elp` = ASSUMED $/EigenLayer-restake-point = $0.005 (range
                  $0.001-$0.01)
- `pts_el_rate` = EigenLayer points / weETH / day ≈ 24 (1 ETH = 1
                  EigenLayer-point per hour, weETH ≈ 1.04 ETH)

Implied-APY component (paid in SY at maturity):
```
imp_apy_value = S_notional * r_eEth * t
              = n_YT * 0.030 * 0.493
              = 0.0148 * n_YT  (units: weETH)
```

Points component:
```
days = t * 365 = 180
ef_pts  = S_notional * pts_rate * days * mult_EF
        = n_YT * 5000 * 180 * 2 = 1.8e6 * n_YT
ef_usd  = ef_pts * usd_per_pt = 1.8e6 * n_YT * 0.001 = 1800 * n_YT USD

el_pts  = S_notional * pts_el_rate * days * mult_EL
        = n_YT * 24 * 180 * 2 = 8640 * n_YT
el_usd  = 8640 * n_YT * 0.005 = 43.2 * n_YT USD
```

Numerical example: 100 WETH (≈ $250k at $2.5k/ETH) buys YT-weETH at, say,
0.025 WETH/YT-notional → n_YT = 4,000 weETH-notional.

- implied APY component: 4000 * 0.0148 = 59.2 weETH (≈ $148k at $2.5k/ETH)
- EtherFi points: 4000 * 1800 = $7.2M (assumed TGE valuation)
- EigenLayer points: 4000 * 43.2 = $173k

Total return on $250k principal under the stated assumptions:
**≈ $148k (implied yield) + $7.2M (EF points) + $173k (EL points) = ~$7.5M**
i.e. **30× principal**, IF assumed point prices materialise.

Downside: if EtherFi/EigenLayer TGEs disappoint (e.g., $0.0001/pt), the
$7.2M shrinks to ~$720k. If they fail entirely (no TGE before maturity),
only the SY-implied-yield $148k is recovered against $250k principal →
40% LOSS of principal. This is the speculative tail of the trade.

## Block pinned
**20_650_000** (~Aug 15 2024). PT/YT-weETH-26DEC2024 active with 4.5 months
to maturity, EtherFi Season 3 + EigenLayer points still accruing, no TGE
yet, YT cheap relative to remaining-points value.

## Risks
- **TGE undershoots** the assumed $/point. Asymmetric: full principal can be
  lost.
- **TGE delayed past maturity**: YT expires before points are tokenised;
  points still accrue to your address off-chain but you no longer hold
  the SY exposure that earns more.
- **Pendle multiplier sunset**: EtherFi can withdraw the Pendle bonus mid-
  cycle (has happened historically), reducing points accrual rate.
- **weETH depeg**: hurts both PT and YT; here it materialises as reduced
  implied-yield portion.
- **Smart-contract risk**: Pendle V4, EtherFi LRT, EigenLayer strategy
  manager.

## Result
Status: theoretical. Market addresses pinned per maturity in PoC source.
Expected PnL: highly sensitive to assumed $/point. Base case under stated
assumptions: **+30× principal** ($250k → $7.5M). 50% probability-weighted
EV under broader uncertainty: **~+200% principal**. Downside tail: full
principal loss minus implied-APY recovery (≈ -40%).
