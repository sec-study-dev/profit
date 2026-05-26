# F07-04: PT/SY redemption arbitrage near maturity

## Mechanism
At Pendle maturity, **1 PT redeems for exactly 1 SY** via `IPYieldToken.redeemPY()`
(after expiry the YT side is worth zero, so PT alone is sufficient). Before
maturity, PT trades at a discount in the Pendle AMM. As the time-to-maturity
approaches zero, the no-arb price of PT in SY units converges to 1.0.

Empirically the AMM is a touch slow to fully converge in the final ~24-72
hours before maturity: it is still a constant-function curve with a time-
decaying scalar, and last-trade impact + thin late-life liquidity can leave
PT marked at 0.998-0.9995 SY/PT even with hours to go. After maturity, PT
becomes a fixed-redemption coupon that anyone can crystallise via
`IPYieldToken.redeemPY()` for exactly 1.0 SY.

The trade: in the final hours/days before maturity, buy PT at <1.0 SY,
hold ≤72h, then call `redeemPY()` at expiry to receive 1.0 SY per PT. The
delta `(1 - P_buy)` is risk-free (modulo gas + smart-contract exposure).

## Why it composes
This is the cleanest Pendle composition because it relies on the *protocol
guarantee* (PT ↔ SY 1:1 at maturity is hard-coded in `PendleYieldToken.sol`)
rather than any market-quality property. The AMM mis-pricing exists because
LP rationality breaks down in the final hours: LPs anticipating maturity
withdraw liquidity to avoid the post-expiry yield-loss penalty in their LP
share, leaving the few remaining quotes wider than they "should" be. Anyone
holding a small inventory of cash can step in and harvest the gap.

It composes with money markets the same way as F07-01/02 (PT as collateral),
but here the time horizon is so short the carry doesn't matter — only the
deterministic redemption gap matters.

## Preconditions
- A Pendle market within ~5 days of maturity.
- Observable PT discount > 0.05% (gas-and-friction breakeven for ~$1M
  trade is ~0.02-0.05% depending on chain congestion).
- Sufficient PT inventory on the AMM at the buy size.
- For PoC purposes: SY is convertible back to a "real" asset (sUSDe,
  weETH etc.) via `redeem(receiver, shares, tokenOut, ...)`.

## Strategy steps
1. Acquire USDC (or WETH) equity.
2. Approve Pendle Router.
3. `swapExactTokenForPt(market=NEAR-MATURITY-MARKET)` at the prevailing
   PT discount.
4. `vm.warp` to a few seconds past `market.expiry()`.
5. Call `redeemPyToToken(YT, ptIn, output=USDC)` on the Router, which
   internally:
   - calls `YT.redeemPY()` for `1 SY per PT`
   - calls `SY.redeem(tokenOut=USDC)` to convert SY → USDC
6. Net result: USDC received > USDC spent by `(1/discount - 1)` adjusted
   for Pendle router fees + SY redeem slippage.

## PnL math
Let:
- `disc` = PT spot in SY units at trade time = 0.9985 (1.5 bps under face)
- `f_amm` = Pendle AMM swap fee, captured in PT received ≈ 5 bps round-trip
- `f_sy` = SY-side redeem slippage / fee ≈ 1 bps (sUSDe is a clean redeem
            path; weETH similar)
- `principal` = $1,000,000 USDC

PT received per USDC: roughly `1 / 0.9985 ≈ 1.001503` PT/USDC (ignoring
AMM slippage). With AMM fee:
```
pt_received  = principal * (1/disc) * (1 - f_amm)
             = 1_000_000 * 1.001503 * 0.9995
             = 1_001_002 PT
```

At maturity each PT redeems for 1 SY ≈ 1 USDe ≈ 0.9998 USDC (post SY-redeem
slippage):
```
usdc_out = pt_received * (1 - f_sy)
         = 1_001_002 * 0.9999
         = 1_000_902 USDC
```

Net: `+902 USDC` on `1_000_000` over ~3 days = **~+11% APY** when
annualised across the holding window, but more meaningfully a
**+0.09% absolute** uplift on the holding period. At higher discounts
(0.995, last-hour panic) the absolute return scales linearly: 0.40% on
the same notional, ~50% APY annualised.

Capacity: bounded by PT AMM depth in the final hours. Historical PT-sUSDe
final-day AMM liquidity: $5-20M. Capacity for this PoC: ~$2-5M before
the buy moves the spot past the redemption value.

## Block pinned
**20_661_000** (~Sep 22 2024) — 4 days before the 26-SEP-2024 PT-sUSDe
maturity. PT trades at small discount; sufficient AMM liquidity remains.
The post-expiry block (20_690_000+) is reached via `vm.warp`.

## Risks
- **Smart-contract risk**: trade is otherwise risk-free, so the dominant
  attack surface is Pendle V4 Router + SY redemption path bugs.
- **SY redemption oracle drift**: if the SY's underlying (sUSDe / weETH)
  is in a state where its share→underlying conversion is stale or
  paused (e.g., Ethena unstake cooldown), the SY redeem call reverts.
  Mitigation: choose markets whose SY accepts a liquid stable as
  `tokenRedeemSy`.
- **AMM front-run**: in the final-hours window, MEV bots monitor the same
  gap; a public mempool buy may be sniped. Private RPC / flashbots
  required for clean execution.
- **Price gap closing on-chain**: someone else buys-and-redeems before you;
  trade size shrinks but PnL per trade does not (the gap is whatever spot
  shows at your buy moment).

## Result
Status: theoretical. Market addresses pinned per maturity in PoC. Expected
PnL on $1M USDC equity: **+$900 to +$4,000 USDC** absolute over a 3-day
hold, depending on the depth of the final-hour discount. Annualised this
is in the 10-50% APY band, but in absolute terms is modest unless deployed
at large scale across many maturities.
