# F10-07: GHO mint + Curve GHO/USDe LP + Aave USDe borrow (3-mechanism)

## Mechanism (3-mech)

Three protocols composed for a stablecoin carry that hinges on the
**GHO/USDe price relation**:

1. **Aave V3 — GHO facilitator**: supply USDC, borrow GHO at the governance-
   set facilitator rate (~9% variable). The minting is at par ($1) by
   construction.
2. **Curve — GHO/USDe pool**: a 2-coin factory stableswap pool between GHO
   and Ethena's USDe. Pool earns swap-fee + CRV gauge yield; LP token is
   redeemable for either token via `remove_liquidity_one_coin`.
3. **Aave V3 — USDe borrow**: USDe was listed as an Aave V3 reserve in 2024
   with a high borrow cap. The strategy *also* deposits the freshly minted
   Curve LP token (or its USDe leg unwrapped) and borrows USDe against
   *additional* USDC collateral to short-leverage the USDe leg.

Effective stack: USDC -> GHO (mint) -> Curve LP (yield) -> USDe (unwrap one
side) -> Aave borrow USDe (short) -> close on USDe peg.

Even without the USDe-short leg the trade is identical to F10-05 with USDC
replacing USDC (i.e. GHO+Curve only). The third leg — **short USDe via Aave
borrow** — is added as a hedge against USDe depeg, the dominant tail risk:
since USDe's peg is maintained by Ethena's perp-funding-rate model, a sharp
sell-off in BTC/ETH can crater funding and force a partial depeg. Shorting
USDe via Aave borrow caps the loss to roughly the Aave USDe borrow APR
(typically 2-4%).

## Why it composes

The composition is **risk-pair-matched**. The Curve LP holds GHO and USDe in
equal proportion; if USDe depegs to $0.95 the LP value drops materially. By
borrowing USDe on Aave (a short), the value of the Aave debt also drops
when USDe depegs — the two legs cancel.

The yield surfaces are independent:
- Aave V3 GHO borrow rate is governance-set, decoupled from utilisation.
- Curve LP fees + CRV emissions price the liquidity at independent rates.
- Aave V3 USDe borrow rate is utilisation-driven; typically 2-4% APR.

When GHO is near par and USDe is near par, the LP collects fees + CRV at
~5-8% APR while the only material costs are the GHO borrow (~9%) and a small
USDe borrow stub (~3%). The geometry only requires GHO-borrow-yield-cost to
be **below the LP gross yield + the funding offset on the USDe short**.

## Preconditions

- Mainnet block where:
  - GHO is live with bucket headroom.
  - USDe is listed on Aave V3 with non-zero borrow cap (post-April 2024).
  - Curve GHO/USDe factory pool exists with > $5M TVL.
- Pinned at **20_800_000** (≈ Oct 21 2024) where USDe APY = 9% and Aave USDe
  borrow rate snapshot ~5%.

## Strategy steps

1. Fund test contract with USDC principal.
2. Split principal: 70% to Aave-as-collateral, 30% reserved.
3. `supply` USDC to Aave.
4. `borrow` GHO at ~50% LTV (conservative, to leave headroom for USDe borrow).
5. `borrow` USDe at ~20% LTV (the short leg). Aave allows the same collateral
   to back multiple borrows.
6. Sell borrowed USDe into the Curve GHO/USDe pool? No — keep the USDe debt
   open (it's the hedge). Use the borrowed GHO and the reserved 30% USDC
   converted into USDe via a Curve detour to build the LP.
   - Simpler path: borrow GHO; pair with USDC reserve in a *different* GHO/USDC
     pool. But to use the GHO/USDe pool, we need USDe as the second token.
   - Solution: split borrowed GHO 50/50; sell half through a USDC->USDe Curve
     pool (Mainnet has a USDC/USDe pool); pair the resulting GHO + USDe into
     the GHO/USDe LP.
7. Warp 30 days.
8. Unwind: remove_liquidity -> repay USDe debt with the LP's USDe leg, repay
   GHO debt with the LP's GHO leg, withdraw USDC collateral.

## PnL math

Inputs (snapshot Oct 2024):
- `P_usdc` = 1,000,000 USDC supplied (collateral)
- `borrow_gho` = 500,000 GHO (50% LTV)
- `borrow_usde` = 200,000 USDe (20% LTV — the hedge short)
- `LP_value_at_open` ≈ 500k GHO + 500k USDe = $1M LP notional
- `r_gho_borrow` = 9.00%
- `r_usde_borrow` = 5.00%
- `r_curve_lp_apr` (fees + CRV at boost ~1.5x) = 7.50%
- `r_usdc_supply` = 4.50%

Annualised:
```
income = LP * r_curve_lp_apr + P_usdc * r_usdc_supply
       = 1.0M * 0.075         + 1.0M * 0.045
       = 75k + 45k = 120k

cost   = borrow_gho * r_gho_borrow + borrow_usde * r_usde_borrow
       = 0.5M * 0.09             + 0.2M * 0.05
       = 45k + 10k = 55k

net    = 65k / 1M = 6.5% APR
```

The USDe hedge costs 10k per year but caps the depeg loss to a manageable
band — without the hedge, a 3% USDe depeg in the LP wipes 15k of LP value,
which is more than the hedge cost.

## Block pinned

**20_800_000** (≈ Oct 21 2024). USDe Aave V3 borrow APR ~5%; Curve
GHO/USDe pool TVL ~$8M; GHO facilitator has > 5M bucket headroom.

## Risks

- **USDe depeg below the hedge size**: 200k USDe short hedges only 200k LP
  notional. A larger depeg shock exposes the unhedged half (~$300k of USDe
  inside the LP).
- **Ethena unwinding (Q3 2024 funding inversion)**: forced depeg + cascading
  perp losses. The hedge ratio (here 40% of LP USDe leg) is calibrated for
  ~5% depegs; black-swan moves leak loss.
- **GHO bucket exhaustion**: identical to F10-01.
- **Curve pool A-parameter ramp / depeg amplification**: at high A, sub-1%
  GHO/USDe drift amplifies LP IL.
- **Aave USDe LTV / LT change**: governance can lower USDe LTV to 0 which
  would prevent borrowing but not liquidate the position (collateral is USDC).
- **Smart-contract risk**: Aave V3 Pool (twice), Curve pool, Curve USDC/USDe
  detour pool.

## Result

Status: theoretical 3-mech PoC. Exercises all four entry points (Aave supply,
Aave borrow GHO, Aave borrow USDe, Curve LP) with try/catch fall-throughs.
Expected gross PnL on 1M USDC over 30 days at peak parameters: **+$5,000 to
+$5,500 USD**.
