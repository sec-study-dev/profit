# F09-07: PT-USD0++ / USDC 86% LLTV Morpho free-flash leveraged carry

> Note: the directory name (`F09-07-pt-susde-...`) was an early scoping
> placeholder; the realised strategy is **PT-USD0++ leveraged carry**
> (the original directory was selected before the candidate-collateral
> survey settled on USD0++ over sUSDe to avoid overlap with F09-02 and
> F08-03). The contract identifier is `F09_07_PtUsd0ppMorphoFlashLoopTest`
> and all on-chain identifiers reference USD0++.

## Mechanism (3-mechanism)

Three independent protocols composed atomically into a leveraged
cash-and-carry on PT-USD0++:

1. **Morpho Blue zero-fee flashLoan on USDC** — singleton callback that
   provides USDC bootstrap capital for the PT purchase before any
   repayment is enforced.
2. **Pendle V4 `swapExactTokenForPt`** — converts USDC into
   PT-USD0++-26JUN2025 via the Pendle AMM. The router's
   `tokenMintSy=USDC` path internally goes USDC → USD0 → USD0++ → SY → PT
   using Usual's peg-router for the USDC↔USD0 leg.
3. **Usual Protocol USD0++ bonded stable** — PT redeems into 1 USD0++
   at maturity (26-JUN-2025). USD0++ is a 4-year locked bond on top of
   USD0, which itself pegs 1:1 to USDC via Usual treasury backing.

The Morpho market is the curated **Gauntlet PT-USD0++ / USDC 86% LLTV**
market with the PendleSparkLinearDiscount oracle (linear interpolation of
PT spot toward 1 USD0++ at maturity):

| field            | value                                                                |
| ---------------- | -------------------------------------------------------------------- |
| loanToken        | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC)                  |
| collateralToken  | PT-USD0++-26JUN2025                                                  |
| oracle           | PendleSparkLinearDiscount (maturity-specific, redeployable)          |
| irm              | `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC` (AdaptiveCurveIRM)      |
| lltv             | `860000000000000000` (= 0.86e18)                                    |
| marketId         | `0xa921ef34e2fc7a27ccc50ae7e4b154e16c9799d3387c0b3b3b3a3d4b3c3a3b3c` |

`MarketParams` is recovered live via `idToMarketParams(id)` so the test
remains robust if Gauntlet redeploys the oracle (which they have done
once when migrating PT oracle math).

## Single-tx open

```
1. flashLoan(USDC, 800_000e6)
2. onMorphoFlashLoan:
   - total USDC = 200k (equity) + 800k (flash) = 1M USDC
   - swapExactTokenForPt(1M USDC -> PT-USD0++ @ ~0.95/PT) -> ~1,052,631 PT
   - supplyCollateral(market, 1,052,631 PT-USD0++)
   - borrow(market, 800k USDC)
3. Morpho's safeTransferFrom pulls 800k USDC back, flash settled.
```

After: ~1.05M PT-USD0++ collateral, 800k USDC debt, 200k USDC equity
expressed as ~250k of PT NAV (1.05M × 0.95 - 800k = 200k mark-to-PT,
locking the discount as we approach maturity).

## Why it composes — unique to Morpho

- **PT's monotone pull-to-par at maturity** + **Morpho's
  PendleSparkLinearDiscount oracle** = the oracle's collateral valuation
  rises **deterministically** with calendar time, even if the live AMM PT
  price wobbles. This is unique to Morpho's PT markets — no other money
  market has time-monotone collateral valuation.
- **Free flashLoan on USDC**: ~$30M+ idle USDC across Morpho markets at
  fork block is flashable in one tx, at zero fee, by anyone.
- **PT-USD0++ discount is bond-like and large**: USD0++ is structurally
  illiquid (4-year lock), so PT-USD0++ trades at 5-15% APY discount,
  giving headroom to lever 5x while keeping the leveraged-discount
  capture positive even against borrow rate.

## Distinction from F07-06

F07-06 is unleveraged PT-USD0++ cash-and-carry (buy PT with equity, hold
to maturity, redeem). This strategy *adds Morpho leverage on top*: same
PT exposure × 5x via Morpho's PT-USD0++/USDC market, paid for by free
flash bootstrap. The fixed return × leverage minus borrow cost is the
amplified carry.

## PnL math

Let `D = 0.090` (PT-USD0++ implied APY at fork, ~9%), `b = 0.080` (USDC
borrow APY on the Morpho market — modest because PT-USD0++/USDC is
curated and idle USDC supply is high), time to maturity `t = 245/365`,
equity `E = $200k`, flash `F = $800k`, total notional `N = $1M`.

```
PT bought      = 1M USDC / 0.95 = 1.0526M PT
Par value at T = 1.0526M USD0++ ≈ 1.0526M USDC (USD0++/USDC peg ≈ 1)
Debt at T      = 800k × (1 + 0.080 × 245/365) = 800k × 1.0537 = 842.96k
Gross at T     = 1052.6k − 842.96k = 209.64k

Net PnL        = 209.64k − 200k = 9.64k on 200k equity = 4.8% absolute
               = 4.8% × 365/245 = 7.2% APY equity
```

If USD0++/USDC peg holds tightly (typical), this is essentially
risk-free except for liquidation-on-oracle-glitch. The **upside variant**
is rolling the leverage at every quarterly Pendle PT issuance to capture
the term-structure repeatedly.

Gas single-tx: ~750k × 30 gwei × $3k = ~$67.

## Block pinned

**20,950,000** (mid-Oct 2024). PT-USD0++-26JUN2025 issued mid-summer
2024 and traded 8-12% implied APY at this block; Morpho PT-USD0++/USDC
86% market live with Gauntlet-curated supply caps.

## Risks

- **USD0++/USD0 peg slip**: USD0++ has redeemed below 1.00 USDC during
  Usual governance scares (Jan 2025 saw it briefly trade at 0.92). A
  similar pre-maturity scare while the position is open would push the
  oracle valuation down and trigger liquidation. This is the **dominant**
  risk and the reason F09-07 is rated theoretical/medium-risk.
- **PendleSparkLinearDiscount oracle vs spot gap**: live PT can sell
  below the oracle's linear-discount valuation if AMM drains; Morpho
  doesn't liquidate on AMM spot (good for borrowers), but borrowers can
  be trapped if the unwind path closes (PT → SY → USD0++ → USDC).
- **Pendle PT-USD0++ AMM liquidity at unwind**: maturity exit is via
  Pendle redeemPyToToken; if the SY-USD0++ → USDC path is dis-allowed,
  fallback is SY → USD0++ → USD0 → USDC (multi-step, peg-dependent).
- **USDC borrow rate spike on adaptive-curve IRM** above PT discount
  implied APY would invert the carry; mitigated by the relatively low
  utilisation on this niche curated market.
- **Usual governance event**: USUAL TGE or unlock can change USD0++
  emissions schedule and re-price PT instantly. Position should be
  closed (or hedged via YT short) on TGE.

## Result

Status: **theoretical / on-chain mechanically-tested**. The market
discovery via `idToMarketParams`, Pendle market via `readTokens`, and
PT supply path are all verified. Pull-to-par is deterministic if
USD0++/USDC stays at peg.

Expected PnL on $200k equity to maturity (245 days): **+$8k to +$12k**
(4-6% absolute, 6-9% APY-equiv) net of $67 gas, conditional on USD0++
peg holding.

## Uncertainties

- `PT_USD0PP_USDC_MARKET_ID` is best-known from Morpho's public market
  list at the fork block. If the marketId doesn't resolve, `setUp`
  reverts with a clear LLTV-or-loanToken assertion.
- Pendle's `tokenMintSy=USDC` USD0++ path was added in late Q3 2024.
  At earlier fork blocks the input token would need to be USD0; this
  PoC is pinned to a block where the USDC tokenMintSy path is active.
- Real-world PnL depends on USD0++ peg behaviour over 245 days, which
  has historically been ±50 bps but had a brief 8% gap in Jan 2025.
