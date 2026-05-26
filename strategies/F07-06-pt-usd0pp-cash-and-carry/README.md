# F07-06: PT-USD0++ cash-and-carry (Usual + Pendle)

## Mechanism
Usual is an RWA-backed stablecoin protocol with two receipt tokens:
- **USD0** — the unlocked / liquid stablecoin (1 USD0 ↔ 1 USDC of backing,
  immediately redeemable).
- **USD0++** — a 4-year locked / bonded variant of USD0 that, in exchange
  for the lock, accrues USUAL governance-token emissions (~25-45% APY in
  USUAL-token terms; cash-equivalent depends on USUAL spot).

Pendle lists a USD0++ market, splitting it into PT-USD0++ and YT-USD0++ with
typical maturity ~12 months from issuance. Because USUAL emissions are
front-loaded and uncertain in cash value, the YT trades rich (the "I want
USUAL pre-TGE" speculator side), which pushes PT to a steep discount —
historically 6-15% implied APY for the 6-12 month leg.

The cash-and-carry trade: buy PT-USD0++ at discount with USDC, hold to
maturity, redeem PT for 1 USD0++ each, then unwind USD0++ → USD0 → USDC via
the Usual unlock window (4-year lock applies to pre-bonded users, but PT
holders receive freshly-minted USD0++ at maturity from the SY redemption
path and may have either a faster `unwrap` path or be forced into a
secondary-market sale on Curve).

## Why it composes
This is a 2-mechanism trade — Pendle + Usual — that capitalises on a
**maturity-mismatch yield**: USD0++ is fundamentally a coupon-paying bond
denominated in USUAL emissions, and Pendle is the cleanest way to short
the future-USUAL-price by selling YT and buying PT. The PT discount IS
the implied breakeven price of USUAL emissions over the period.

The composition is interesting because:
1. **Pendle freezes a discount** on a relatively new stablecoin with
   complex tokenomics, making the trade auditable in `USDC` terms even
   though the underlying yield is in `USUAL`.
2. **The Usual peg backstop** (USD0 ↔ USDC at the protocol bonding curve)
   provides the final USD leg, anchoring PT redemption value within a
   tight band of $1.

It is NOT a 3-mechanism because we don't add a leverage venue: USD0++ is
not (yet) listed on Morpho/Aave as collateral with a Pendle-aware oracle
during 2024. If/when that lands, this strategy auto-upgrades to a 3-mech
loop similar to F07-01.

## Preconditions
- Fork block before PT-USD0++-26JUN2025 maturity, with the Pendle market
  live and AMM liquidity present (≥ $5M TVL).
- USD0++ secondary market (Curve USD0++/USD0 pool) holds peg within ±0.5%.
- USDC ↔ USD0 bonding-curve route open (Usual treasury solvent).

## Strategy steps
1. Acquire USDC equity.
2. Approve Pendle Router V4 to pull USDC.
3. `swapExactTokenForPt(market=PT-USD0++-26JUN2025)` with all USDC →
   receive PT-USD0++ at discount.
4. (Hold for ~8 months; emissions stream to YT holders not PT.)
5. At maturity (`vm.warp` past expiry), call `redeemPyToToken(YT, ptIn,
   output=USDC)` — or fall back to the manual SY → USD0++ path if the SY
   doesn't accept USDC as tokenRedeemSy.
6. Final unwind: USD0++ → USD0 via Usual protocol unlock or Curve
   USD0++/USD0 pool → USD0 → USDC via Usual peg.

## PnL math
Let:
- `P_buy`  = PT-USD0++ spot ≈ 0.92 USDC (mid-Oct 2024 quote for 8-month
            maturity, ~10% implied APY)
- `P_mat`  = 1.0 USD0++ → 0.998 USDC after the USD0++ → USD0 → USDC unwind
- `t`      = 250 / 365 ≈ 0.685 years
- `r_pt`   = (0.998 / 0.92 − 1) / 0.685 ≈ 12.4% APY
- Fees: Pendle AMM ~10 bps, USD0++/USD0 Curve swap ~5-15 bps if forced to
  secondary market, USD0 → USDC Usual peg ~5 bps.

Absolute return on $1M USDC over ~8 months:
```
usdc_out = 1_000_000 * (0.998 / 0.92) * (1 − 0.0030)  (cumulative fees)
         = 1_000_000 * 1.0848 * 0.997
         = 1_081_578 USDC
pnl      = 81_578 USDC absolute (~8.2% on 8 months ≈ 12.0% APY)
```

Capacity: bounded by AMM PT inventory at the buy size. PT-USD0++ markets
historically show $5-25M TVL; capacity ~$2-5M before AMM impact dominates.

## Block pinned
**20_950_000** (~Oct 17 2024). PT-USD0++-26JUN2025 trading at ~0.92 with
~8 months to maturity, ~10% implied APY. Usual treasury solvent; USD0++
secondary peg within ±0.3% of $1.

## Risks
- **Usual treasury insolvency / USD0 depeg.** The entire trade collapses
  to whatever the Usual RWA backing recovers. Historical worst case:
  USD0/USDC has held within ±0.5% but has not been stressed in a panic.
- **USD0++ unlock pathway change.** Usual could alter the unlock rules
  for late entrants; PT holders receive USD0++ at maturity which may have
  a forced lockup, forcing exit through secondary AMM and eating the peg
  discount.
- **USUAL TGE outcome.** If USUAL emissions are revalued post-TGE such
  that 4-year locked USD0++ is worth materially less than 1 USD0 in
  secondary markets, the PT redemption value falls.
- **Pendle V4 router / SY redeem bug.** Standard smart-contract surface.
- **Maturity timing.** The PoC warps `vm.warp(_expiry + 1h)`; in live
  deployment the unwind has to compete with other PT holders for AMM
  exit at maturity (Curve USD0++/USD0 depth limits).

## Result
Status: theoretical. PoC source includes the SY-redeem fallback because
the SY-USD0++ may not expose USDC as a `tokenRedeemSy`. Expected PnL on
$1M USDC equity: **+$60k to +$85k USDC absolute** over ~8 months (≈
9-13% APY), net of standard frictions. The trade is dollar-neutral in
USD0 terms; the USDC-leg PnL depends on Usual's peg integrity.
