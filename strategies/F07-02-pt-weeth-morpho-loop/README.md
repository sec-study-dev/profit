# F07-02: PT-weETH leveraged buy on Morpho (ETH-side carry)

## Mechanism
weETH is EtherFi's wrapped restaked-eETH receipt: an ETH-denominated asset
that internally accretes both Lido-style staking yield (~3.0% APR) and
EigenLayer / EtherFi point rewards (off-chain in points; valued in cash at
TGE). Pendle's PT-weETH freezes the implied ETH-staking APY portion into a
discount-to-face: at issuance, 1 PT-weETH costs ~0.96 weETH worth of WETH
and matures to redeem for exactly 1 weETH (which itself accretes vs ETH).

Morpho Blue's **PT-weETH / WETH** isolated market (Gauntlet-curated, 86% or
91.5% LLTV variants) uses a `PendleSparkLinearDiscount` oracle: the PT is
priced on a deterministic linear path from spot-at-listing to 1.0 weETH at
maturity. The borrower thus pays WETH borrow APY on Morpho and earns:
- the PT discount (i.e., implied fixed APY between trade time and maturity)
- weETH internal rate appreciation (since PT redeems for weETH, not ETH)
- minus the WETH borrow rate × leverage

This is the ETH-side analogue of F07-01 (stable-side). Leverage compounds
the implied fixed ETH-staking APY spread above WETH borrow APY.

## Why it composes
PT-weETH × Morpho works because Morpho's linear-discount oracle is honest
about what a PT actually IS: a zero-coupon claim on the underlying SY at a
known date. Pricing it linearly (rather than via AMM spot) means borrowers
are not liquidated by short-term AMM moves; they can only be liquidated by
weETH itself losing value vs WETH (a depeg / slashing event). Empirically
weETH/ETH has held within ±0.4% of NAV since launch.

The compound mechanism stacks cleanly with F02 (LRT looping) on the
collateral side: a PT-weETH position is structurally identical to a leveraged
LRT loop, except the "yield" is *locked* at the PT-buy moment instead of
floating. That trade-off pays off when the WETH borrow APY trend is rising
(you locked in past day's quote) or when the trader has a strong view that
the post-TGE points value will not justify YT prices.

## Preconditions
- Fork block before PT-weETH-26DEC2024 maturity, with the Morpho market live.
- Pendle PT-weETH-26DEC2024 AMM has enough WETH-side liquidity (typically
  20-40k WETH historical TVL).
- Morpho PT-weETH/WETH has enough WETH supply for the loop (50-100k WETH
  supply cap historically).
- Implied PT discount APY > WETH borrow APY at fork block.

## Strategy steps
1. Acquire WETH principal.
2. Approve Pendle Router and Morpho.
3. `swapExactTokenForPt(market=PT-weETH-26DEC2024)` with all WETH → receive
   PT-weETH.
4. `supplyCollateral(PT-weETH)` to Morpho's PT-weETH/WETH market.
5. Loop N times:
   a. Read position; compute borrowable WETH at target LTV.
   b. `borrow(WETH)` from Morpho.
   c. `swapExactTokenForPt` to convert WETH to more PT-weETH.
   d. `supplyCollateral` the new PT.
6. Position holds `K = 1/(1-L)` × PT-weETH and `K-1` × WETH debt.
7. Exit at maturity via `redeemPyToToken(YT, PT, output=WETH)` which redeems
   PT for SY (=weETH) and unwraps to WETH.

## PnL math
Let:
- `P_buy`     = PT-weETH spot in WETH at trade time = 0.965 WETH
- `P_mat`     = redemption value in WETH at maturity = weETH/ETH rate at
                maturity ≈ 1.05 (8 months of weETH NAV growth from listing
                + final settlement)
- `t`         = 180 / 365 ≈ 0.493 years
- `r_pt`      = (1.05 / 0.965 - 1) / 0.493 ≈ 17.85% APY (implied fixed,
                gross of fees and weETH NAV growth between buy and maturity)
- `r_borrow`  = WETH variable borrow APY on Morpho ≈ 2.6%
- `L`         = effective LTV per loop = 0.87 (under 91.5% LLTV)
- `K`         = 1 / (1 - L) = 7.69

Net APY on equity (WETH-denominated):
```
net_apy = K * r_pt - (K - 1) * r_borrow
        = 7.69 * 0.1785 - 6.69 * 0.026
        = 1.373  - 0.174
        = 1.199   (~120% APY in WETH terms)
```

Apply realistic frictions: AMM slippage on each buy (~0.15% per swap at this
size, four swaps = 0.6%), exit slippage / minor rate drift, Morpho curator
fee (~10% of net spread). Realistic **~80-95% APY on equity in WETH terms**
over the 180-day window, i.e. ~40-47% absolute return.

Points exposure: holding PT *does NOT* accrue points (those go entirely to
YT). The PT carry is the pure ETH-staking implied APY, no point speculation.

## Block pinned
**20_650_000** (~mid August 2024) — PT-weETH-26DEC2024 has ~4.5 months to
maturity, Pendle AMM and Morpho market both live and liquid, weETH NAV
appreciating cleanly above 1.04.

## Risks
- **weETH depeg / EtherFi slash.** If weETH's internal NAV vs ETH drops
  (slashing, withdrawal queue stress), the PT redemption value falls and
  the Morpho oracle will start marking the collateral down on the linear
  schedule that ends at the *new* weETH NAV. Holders can be liquidated.
- **WETH borrow rate spike.** Morpho's adaptive curve IRM ramps borrow APY
  steeply above ~90% utilisation. A vault re-allocation away from this
  market can lift borrow APY past PT implied APY.
- **PT AMM drying up before maturity.** Forces holding to maturity (lower
  optionality) and locks exit timing.
- **Pendle V4 router bug / Morpho oracle bug.** Standard smart-contract
  surface.
- **Gas at exit.** Maturity redemption is one tx per leg; cheap on its own
  but the unwind path to USDC (if needed) goes through curve/uni.

## Result
Status: theoretical. Market addresses pinned by maturity in PoC source.
Expected PnL on 100 WETH equity at K≈7-8: **+40 to +48 WETH** absolute over
the 180-day window in WETH-denominated NAV (gross of point value, gross of
gas). USD-equivalent depends on ETH price; at $2.5k/ETH ~$100-120k.
