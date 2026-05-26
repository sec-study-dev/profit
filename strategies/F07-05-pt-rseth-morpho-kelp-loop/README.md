# F07-05: PT-rsETH leveraged buy on Morpho (Kelp + Pendle + Morpho)

## Mechanism (3-mechanism)
1. **Kelp DAO rsETH** — ETH-denominated liquid restaking receipt. rsETH/ETH
   rate appreciates with EigenLayer + native restaking yield (~3.2-3.6% APY
   gross) and accrues EigenLayer + Kelp Miles points off-chain. Kelp's NAV
   getter (`getRsETHAmountToMint`) holds the on-chain truth for share→ETH
   conversion.
2. **Pendle PT-rsETH-26DEC2024** — splits the rsETH yield into a fixed-
   discount zero-coupon: PT spot trades ~0.95-0.97 WETH at the buy moment,
   redeems for 1 rsETH at maturity (which itself is worth ~1.04 ETH by then).
3. **Morpho Blue PT-rsETH/WETH** — isolated market with
   `PendleSparkLinearDiscount` oracle, 86% LLTV. The oracle prices PT on a
   straight line from spot-at-listing → 1 rsETH at maturity, so the borrower
   is *not* liquidated by AMM spot dislocations, only by rsETH itself losing
   value vs WETH (i.e., Kelp slashing / depeg).

Composition: buy PT-rsETH at discount → post as Morpho collateral → borrow
WETH near LLTV → re-buy PT with the borrowed WETH → repeat. After N≈4 loops
the position is `K = 1/(1-L) ≈ 5-6x` PT-rsETH against `K-1 ≈ 4-5x` WETH debt.

## Why it composes
This stacks three independent risk surfaces that each give up something to
make the overall trade better:
- **Kelp commits restaking yield** to rsETH NAV (the underlying carry).
- **Pendle freezes that yield** into a known-at-trade-time number (you no
  longer care about restaking-yield variance; you only care about whether
  Kelp delivers on the floor).
- **Morpho's linear-discount oracle commits to the deterministic
  redemption path**, eliminating AMM-spot liquidation risk. You can hold to
  maturity even if the Pendle AMM widens to a 10% discount in the interim.

The result: lever a fixed APY claim by ~5x using the same WETH funding rate
Morpho uses for everything else, and walk away with 4-5x the PT carry minus
4-5x the WETH borrow rate. Empirically this is a positive spread for any
fork block where rsETH implied APY ≥ 4-5%.

## Preconditions
- Fork block before PT-rsETH-26DEC2024 maturity, Morpho market live.
- Pendle PT-rsETH AMM has WETH-side liquidity at the buy size (typical
  20-50k WETH AMM TVL for the Dec-24 maturity from mid-2024 onward).
- Morpho PT-rsETH/WETH has WETH supply (Gauntlet vaults allocate here).
- Implied PT discount APY > WETH borrow APY (true for 70-80% of 2024).

## Strategy steps
1. Acquire WETH equity (here `100 WETH`).
2. Approve Pendle Router V4 to pull WETH; approve Morpho to pull PT-rsETH.
3. `swapExactTokenForPt(market=PT-rsETH-26DEC2024)` with all WETH →
   receive PT-rsETH at the AMM discount.
4. `supplyCollateral(PT-rsETH)` to Morpho.
5. Loop `N=4` times:
   - read Morpho position; compute borrowable WETH at `LTV=82%` (under
     86% LLTV) using oracle's expected PT/WETH rate (here approx 0.955).
   - `borrow(WETH)` from Morpho.
   - `swapExactTokenForPt` with the WETH → more PT.
   - `supplyCollateral`.
6. Final position: ~5-6× PT collateral vs WETH equity, with ~4-5× WETH debt.
7. (Exit, conceptual) At maturity: `redeemPyToToken(YT, ptBal, output=WETH)`
   → router calls `YT.redeemPY` (PT 1:1 → SY=rsETH) → `SY.redeem(WETH)` →
   repay Morpho.

## PnL math
Let:
- `P_buy` = PT-rsETH spot ≈ 0.955 WETH (mid-Aug 2024 quote)
- `P_mat` = PT redemption value in WETH at maturity = rsETH/ETH NAV ≈ 1.04
- `t`     = 130 / 365 ≈ 0.356 years
- `r_pt`  = (1.04/0.955 − 1) / 0.356 ≈ 25.0% APY implied fixed
- `r_b`   = WETH borrow APY on Morpho ≈ 2.5-3.0%
- `L`     = 0.82 effective per-loop LTV
- `K`     = 1 / (1 − L) = 5.56

Net APY on equity (WETH-denominated):
```
net_apy = K * r_pt − (K − 1) * r_borrow
        = 5.56 * 0.25 − 4.56 * 0.03
        = 1.39 − 0.137
        = 1.253   (≈125% APY in WETH)
```

Apply realistic frictions: Pendle AMM fees ~10 bps/swap × 5 swaps = 0.5%,
exit slippage ≈ 0.2%, Morpho curator share ≈ 10% of net spread. Realistic
**~80-95% APY in WETH terms** over the holding window, i.e. ~28-34%
absolute return on 100 WETH equity (~28-34 WETH ≈ $70-85k @ $2.5k/ETH).

Points exposure: PT does NOT accrue Kelp Miles or EL points (those go to
YT). The carry is pure implied fixed APY locked at trade time.

## Block pinned
**20_650_000** (~Aug 14 2024). PT-rsETH-26DEC2024 has ~4 months to maturity,
Pendle AMM liquidity adequate, Morpho PT-rsETH/WETH market live with WETH
supply.

## Risks
- **rsETH depeg / Kelp slashing.** If Kelp's NAV vs ETH falls (operator
  slashing, withdrawal queue stress), the PT redemption value declines and
  the Morpho linear-discount oracle marks collateral down accordingly,
  triggering liquidation.
- **WETH borrow rate spike on Morpho.** The Adaptive Curve IRM ramps APY
  steeply above ~90% utilisation; a withdrawal of WETH supply by a
  curated vault re-allocator can lift borrow APY past PT implied APY.
- **AMM dry-up before maturity** — forces hold-to-maturity (loses exit
  optionality but does not kill PnL).
- **Smart-contract risk** — Pendle V4, Morpho Blue, Kelp deposit pool.
- **Maturity unwind path** — rsETH unstaking has a 7-day window via Kelp's
  withdrawal manager; an exit forcing pre-maturity sale routes via the
  Pendle AMM and pays the AMM exit slippage.

## Result
Status: theoretical. Market addresses pinned per maturity in PoC source.
Expected PnL on 100 WETH equity at K≈5.5: **+28 to +34 WETH absolute** over
the 130-day window in WETH-denominated NAV (gross of point value, gross of
gas). USD-equivalent at $2.5k/ETH: ~$70-85k.
