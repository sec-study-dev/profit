# F02-07: weETH PT/YT split — sell PT for cash, keep YT, leverage via Morpho flashloan

## Mechanism
Combines **three distinct mechanisms** to build a maximally-leveraged YT-weETH
position with minimal at-risk equity:

1. **EtherFi LRT (eETH → weETH)** — mint the underlying LRT from ETH.
2. **Pendle YT/PT split (`mintPyFromToken`)** — atomically convert weETH into
   matched PT-weETH + YT-weETH at SY exchange rate, then sell the PT side for
   WETH (keeping the YT side, which receives the *entire* underlying yield +
   point stream until maturity).
3. **Morpho free flashloan** — bootstraps the capital so the strategy can mint
   far more weETH than the equity tranche supports, sell the resulting PT for
   WETH, repay the flashloan from PT proceeds, and end up with a YT-only book
   funded almost entirely by the PT-sale receivable.

The economic insight: 1 weETH split via Pendle's `mintPyFromToken` produces
1 PT + 1 YT. PT trades at ~95-97% of the underlying SY price (because PT pays
SY's face value at maturity); YT trades at ~3-5% (the residual). Selling PT
recovers ~96% of the WETH cost; the strategy *net-pays* ~4% to hold 1 YT.

```
For each 1 WETH spent in the loop:
  → mint 1 SY-weETH (~1 weETH-equiv)
  → split into 1 PT + 1 YT
  → sell PT for ~0.96 WETH
  → net cost = 0.04 WETH per 1 YT held
  → effective leverage on YT exposure: 1 / 0.04 = 25x
```

This is **structurally different** from F02-02 (which buys YT directly via
swapExactTokenForYt at the AMM-implied YT/SY ratio). The PT-sale path is the
synthetic "mint and unbundle" route: it locks the YT cost-basis at the AMM
PT price (slightly different from the YT price), so the two paths price-arb
each other in a healthy market.

## Why it composes (3 mechanisms)
- **EtherFi** supplies the underlying point-emitting asset.
- **Pendle** decouples points from cash (split + sell PT).
- **Morpho flashloan** bootstraps the leg-build so the strategist's actual
  equity is committed only to the residual YT cost (~4% of the looped notional).

## Preconditions
- Block: 19,400,000 (early March 2024). At this block:
  - Pendle `PT-eETH-27JUN24 / SY-weETH` market live (~16 weeks TTM).
  - Morpho Blue's `flashLoan()` (zero-fee) live.
  - EtherFi liquidity pool open, no cap on `deposit()`.
- WETH borrow source = Morpho free flashloan (no fee, no IRM exposure).
- PT discount to SY ~3-5% at this point in season-2.

## Strategy steps
1. Receive 100 WETH equity.
2. Flash 1900 WETH from Morpho Blue → total 2000 WETH on hand.
3. Inside callback:
   a. Unwrap 2000 WETH → ETH; deposit to EtherFi → mint 2000 eETH (1:1).
   b. Wrap eETH → weETH: ~1963 weETH (at rate 1.0186).
   c. Approve Pendle Router on weETH (or SY-weETH, depending on Pendle interface).
   d. `IPendleRouter.mintPyFromToken(receiver=this, YT=YT-weETH-27JUN24,
      minPyOut=0, TokenInput{tokenIn=weETH, ...})` → atomically converts
      weETH to (PT, YT) at SY exchange rate. Receive ~1963 PT + ~1963 YT.
   e. Sell ALL the PT for WETH: `swapExactPtForToken(receiver=this,
      market=PT-eETH-27JUN24 market, exactPtIn=ptBalance, output=TokenOutput{
      tokenOut=WETH, ...}, limit)` → receive ~1903 WETH (at PT discount ~3%).
   f. Repay flashloan: 1900 WETH back to Morpho. ~3 WETH residual + 1963 YT
      remain (the YT is the entire alpha).
4. Hold YT until 27-Jun-2024 (or unwind earlier).
5. At maturity: each YT pays out the accrued underlying yield + the strategist
   has already captured the full point stream over the holding period.

## PnL math
Inputs: 100 ETH equity, 19x notional leverage, ~120-day hold to maturity.

```
Cost basis:
  Flash 1900 WETH; total 2000 WETH converted.
  weETH minted ≈ 1963 (rate 1.0186).
  PT sold for ≈ 1903 WETH (PT@0.97 of SY, slippage ~5bp).
  WETH residual = 1903 - 1900 (flash) = 3 WETH ≈ 3 ETH.
  Equity spent on YT = 100 - 3 = 97 ETH worth of YT (≈ 1963 YT-weETH).

Cash leg (over 120 days):
  YT decay: full YT cost = -97 ETH (worst case if no early-exit rebalance).
  Variable yield captured (3.0% APR weETH yield on 1963 notional):
    = 1963 × 3.0% × 120/365 = 19.4 ETH (delivered as rewards on YT redemption)
  Net cash carry ≈ -78 ETH (≈ -$234,000 at ETH=$3000)

Point leg (120-day):
  EtherFi loyalty (S2 rate, 10k/ETH/day boost halved):
    1963 × 10k × 120 = 2.36B pts
    @ $0.00005/pt (conservative)         = ~$118,000
    @ $0.0002/pt (post-S1 high band)     = ~$472,000
  EigenLayer rs-pts:
    1963 × 1 ETH-day × 120 = 235,560 ETH-days
    @ $1/ETH-day (S2 expected)           = ~$235,500
    @ $2/ETH-day (S1 realised)           = ~$471,000
```

Outcome on $300k equity, 120 days:
- Bear (no point conversion): **-$234,000** (-78%)
- Conservative (cash + low points): **+$120k** (+40%)
- Base (cash + mid points): **+$590k** (+197%)
- Bull (cash + S1-realised points): **+$1.5M+** (+500%)

The structural distinction from F02-02: F02-07 achieves **~20x more YT-per-equity**
because the cost-basis is the PT-discount (~4%) rather than the YT/SY market
price (~3%); however the absolute YT count is higher, so absolute point exposure
scales accordingly, with a strictly larger downside if points fail.

## Block pinned
- Fork block 19,400,000 (early March 2024).
- Pendle `PT-eETH-27JUN24 / SY-weETH` market:
  `0xf32e58f92e60f4b0a37a69b95d642a471365eae8` (verified at
  https://etherscan.io/address/0xf32e58f92e60f4b0a37a69b95d642a471365eae8).
- YT-weETH-27JUN2024: `0xfb35Fd0095dD1096b1Ca49AD44d8C5812A201677`.
- PT-weETH-27JUN2024: `0xc69Ad9baB1dEE23F4605a82b3354F8E40d1E5966`.
- SY-weETH: derivable from market; via Pendle's `mintPyFromToken` we pass YT
  address and SY is resolved internally.

## Risks
- **PT discount widening.** If implied APY spikes (e.g. pre-airdrop selling),
  PT can trade at 80-85% of SY; the flash-unwind PT-sale becomes capital-negative.
- **YT decay materially negative.** Without point realisation, every day costs
  the strategy ~0.6 ETH (over 120-day TTM, that's full equity loss).
- **Flashloan repay infeasible** if Pendle PT liquidity is thin — the entire
  loop must close in a single tx, so the PT sale's slippage is critical.
- **EtherFi caps / pauses.** If `deposit()` is paused or capped, the eETH mint
  step reverts; entire strategy aborts.
- **Pendle smart-contract complexity.** Pendle V4's `mintPyFromToken` invokes
  multiple internal contracts; any bug in path-routing aborts the loop.
- **Points dilution.** Same as F02-01/02 family-wide risk.

## Result
Status: **theoretical**. Mechanics are reproducible in a single tx via Pendle
V4 + Morpho flashloan. The entire alpha is the point-claim multiple.

PnL range (120-day, 100 ETH equity = $300k):
- Bear (zero point realisation): **-$234,000** (locked-in time decay)
- Conservative: **+$120k** (+40%)
- Base (post-S1 historical multiples): **+$500-700k** (+170-235%)
- Bull (S1-like FDV): **+$1.5M+**
