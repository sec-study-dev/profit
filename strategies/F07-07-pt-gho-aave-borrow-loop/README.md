# F07-07: PT-sUSDe collateral on Morpho + GHO debt (Pendle + Morpho + GHO facilitator)

## Mechanism (3-mechanism)
1. **Pendle PT-sUSDe-26DEC2024** — fixed-discount zero-coupon claim on
   1 sUSDe at maturity. Implied APY at trade time ~15-22%.
2. **Morpho Blue PT-sUSDe/GHO market** — isolated lending market with
   `PendleSparkLinearDiscount` oracle and GHO as the loan token. LLTV 86.5%.
3. **GHO facilitator / Aave V3** — GHO is mint-on-demand at a borrow rate
   set by the Aave DAO (currently ~6.5% APY), which is structurally lower
   than the equivalent USDC borrow rate on Morpho's PT-sUSDe/USDC market
   (~7-9% APY) because GHO can be over-minted against the entire Aave
   collateral base. The Morpho PT-sUSDe/GHO market lets a borrower pay the
   *Morpho-curved* GHO rate (often pinned near the Aave facilitator rate)
   while supplying PT-sUSDe as collateral.

   The third mechanism leg is the **GHO/USDC peg-discount carry**: GHO
   has historically traded at 30-80 bps under USDC on Balancer's
   GHO/USDC/USDT stable pool. Borrowing 1 GHO and swapping to 0.997 USDC
   costs the trader 30 bps in peg but is paid back at 1:1 GHO at unwind,
   so the GHO depeg works in the borrower's favour at exit (when the
   borrower buys back GHO with USDC at the same discount).

Composition: buy PT-sUSDe with USDC → post PT to Morpho → borrow GHO →
swap GHO → USDC on Balancer → re-buy PT → loop. At maturity, PT redeems
for 1 sUSDe → unwind sUSDe to USDC → swap USDC → GHO on Balancer →
repay Morpho.

## Why it composes
This is a 3-mechanism extension of F07-01 where the **debt asset is
swapped for a structurally-cheaper one** (GHO) at the same Morpho
collateral. The benefits stack:
- **Lower borrow APY**: GHO on Morpho PT-sUSDe market quotes typically
  60-150 bps below the USDC variant.
- **Peg discount on swap-out**: borrow 1 GHO at $1, sell for $0.997 USDC,
  buy back at $0.997, repay 1 GHO. Round-trip is +30 bps versus the
  USDC-borrow version (zero peg gap).
- **PT carry unchanged**: PT-sUSDe is the same instrument; the implied APY
  doesn't depend on debt currency.

Risks introduced by adding the third mechanism:
- **GHO peg widening at repay**. If GHO trades at $1.005 at unwind (above
  peg), the round-trip flips negative. Empirically GHO has stayed in
  [$0.992, $1.002] since launch.
- **GHO facilitator cap**. Morpho's PT-sUSDe/GHO market's GHO supply is
  ultimately bounded by the facilitator's bucket level; large flows
  contend with Aave-side borrowers for the same GHO.

## Preconditions
- Fork block before PT-sUSDe-26DEC2024 maturity, with Morpho PT-sUSDe/GHO
  market live.
- GHO Aave facilitator has non-zero bucket headroom (≥ position's GHO
  debt). PoC `ghoFacilitatorHeadroom` view inlines the check.
- Balancer GHO/USDC/USDT pool has ≥ position-size depth (typically $5-15M).
- Implied PT-sUSDe APY > effective GHO cost (Morpho rate − peg discount).

## Strategy steps
1. Acquire USDC equity.
2. Approve Pendle Router, Morpho, Balancer Vault.
3. `swapExactTokenForPt(market=PT-sUSDe-26DEC2024)` with all USDC → PT.
4. `supplyCollateral(PT-sUSDe)` to Morpho PT-sUSDe/GHO market.
5. Loop `N=3`:
   a. read Morpho position; compute borrowable GHO at LTV=82% (under
      86.5% LLTV).
   b. `borrow(GHO)` from Morpho.
   c. `swap(GHO → USDC)` on Balancer GHO/USDC stable pool.
   d. `swapExactTokenForPt` with the USDC → more PT.
   e. `supplyCollateral`.
6. (Exit conceptual) Maturity: PT → sUSDe → USDe → USDC; swap USDC →
   GHO; `repay` to Morpho.

## PnL math
Let:
- `P_buy`     = PT-sUSDe spot ≈ 0.965 USDC
- `P_mat`     = 1.0 sUSDe → ~1.01 USDC (Ethena vault appreciation)
- `t`         = 60 / 365 ≈ 0.164 years
- `r_pt`      = (1.01 / 0.965 − 1) / 0.164 ≈ 28.5% APY implied fixed
- `r_gho`     = Morpho PT-sUSDe/GHO borrow APY ≈ 6.5%
- `peg_gap`   = +30 bps on round-trip GHO ↔ USDC
- `L`         = 0.82
- `K`         = 1 / (1 − L) = 5.56

Net APY on equity:
```
gross_loop_apy  = K * r_pt − (K − 1) * r_gho
                = 5.56 * 0.285 − 4.56 * 0.065
                = 1.585 − 0.296
                = 1.289   (~129% APY)

peg_bonus       = peg_gap * (K − 1) annualised over t
                = 0.003 * 4.56 / 0.164
                = ~8.3% APY incremental
                                = 0.0837 per-year boost ⇒ realised over t
                                  = 0.0137 absolute on equity for the 60-day hold

total_apy       ≈ 137% APY
```

Apply realistic frictions: Pendle AMM ~10 bps × 4 swaps = 0.4%, Balancer
GHO/USDC ~3 bps × 3 swaps = 0.1%, Morpho curator share ~10%. Realistic
**~90-110% APY in USDC terms** over the 60-day window, i.e. ~15-18%
absolute return on $1M equity (~$150-180k USDC).

## Block pinned
**21_000_000** (~Oct 26 2024). PT-sUSDe-26DEC2024 has ~2 months to maturity,
Morpho PT-sUSDe/GHO market live, GHO facilitator bucket has headroom,
Balancer GHO/USDC pool deep.

## Risks
- **GHO peg widens > 80 bps**. At ≥ +80 bps GHO over USDC, the swap path
  inverts and the strategy becomes worse than the F07-01 USDC variant.
- **sUSDe NAV depeg / Ethena hedge failure**. Same as F07-01: PT
  redemption value falls, Morpho linear-discount oracle marks collateral
  down on the new path.
- **GHO Aave facilitator cap reduced by governance**. AaveDAO can vote
  to lower the GHO bucket; outstanding Morpho positions are not directly
  liquidated, but new borrows fail and the carry has to be unwound.
- **Morpho PT-sUSDe/GHO market depth**. The market is smaller than the
  USDC variant; capacity for this PoC is bounded at ~$10M before borrow
  utilisation spikes the IRM curve.
- **Smart-contract surface**: Pendle V4, Morpho Blue, Balancer V2, Aave
  V3 GHO facilitator (3 contracts to audit).

## Result
Status: theoretical. PoC source posts PT to Morpho and routes borrowed
GHO through Balancer; the exit unwind is documented but only the open
position is computed in `_endPnL`. Expected PnL on $1M USDC equity at
K≈5.5: **+$150-180k USDC absolute** over the 60-day window (gross of gas,
gross of tail re-pegging risk).
