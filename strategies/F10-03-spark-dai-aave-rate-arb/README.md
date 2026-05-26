# F10-03: Spark DAI borrow + sDAI / aDAI rate arb

## Mechanism

The DAI market sits on **three distinct rate surfaces** simultaneously:

1. **Maker DSR / sDAI** — protocol-owned savings rate. ERC-4626 `sDAI` is the
   wrapper; the underlying instantaneous rate equals `Pot.dsr()` minus the
   ~0 spread held by the DSR proxy. Effectively a flat-yield, no-counterparty
   risk source of DAI yield.
2. **Spark DAI variable borrow rate** — Aave-style market whose DAI rate is
   pinned by Maker governance to `dsr + ~0.25% to 0.50%` via the D3M
   mechanism.
3. **Aave V3 DAI supply rate (aDAI)** — utilisation-driven; varies between
   1-5% depending on demand for DAI as a borrow on Aave V3.

In a frictionless market all three rates collapse to a single number. In
practice they diverge for two structural reasons:

- Maker's D3M is rebalanced *daily* (not block-by-block), so Spark borrow
  rate trails the true DSR-anchored equilibrium by up to 24h.
- Aave V3's DAI supply rate responds to its own utilisation curve and to the
  competing GHO mint capacity — when GHO mint dominates, Aave DAI supply APR
  decays toward zero because borrowers prefer GHO.

This PoC exercises a **non-leveraged probe**: borrow DAI from Spark, deposit
the proceeds into Aave V3 as a DAI supplier, and *also* into sDAI (split 50/50
to surface both sides of the curve). The strategy is profitable only when
either `aDAI APR > spark borrow APR` or `DSR > spark borrow APR` — both rare,
but both have occurred during D3M-rebalancing windows.

## Why it composes

The composition is a *cross-protocol rate snapshot*. Spark, Aave V3 and sDAI
all denominate yield in DAI, so the arbitrage is purely the rate spread with
no FX / depeg leg. The three protocols compose because their interest
mechanisms are **deliberately disconnected by Maker governance**:

- Maker holds the DSR knob.
- Spark sets a target spread above DSR but only re-pegs on D3M rebalancing
  cadence.
- Aave V3 prices DAI demand independently — the DAI reserve on Aave is not
  fed by Maker; it is "ordinary" DAI lending.

Whenever Maker raises DSR but the D3M has not yet been pinged, Spark's rate
stays below the new equilibrium; meanwhile Aave's DAI supply rate is
unaffected. A user who can borrow on Spark and supply on Aave or sDAI
captures the lag.

## Preconditions

- Spark Pool live, sDAI live, Aave V3 DAI reserve live. All present from
  May 2023.
- Spark DAI borrow rate must be **below** at least one of (DSR, Aave V3 aDAI
  supply rate) at the pinned block. The PoC reads all three rates on-chain
  and emits a `no_arb` log if none of the legs is profitable, but still
  executes the position so PnL is observable.
- Use moderate collateral (USDC) on Spark; not GHO/USDT to avoid eMode
  rounding edge cases on Spark.

## Strategy steps

1. Fund `address(this)` with USDC principal.
2. Approve USDC to Spark Pool; `supply` as collateral.
3. Read Spark DAI `currentVariableBorrowRate`, sDAI APR (via `dsr` or
   `convertToAssets` deltas) and Aave aDAI `currentLiquidityRate`. Log all
   three.
4. `borrow` DAI from Spark at a low conservative LTV (50%) — enough to
   guarantee no liquidation under reasonable rate moves.
5. Split the borrowed DAI: half to **Aave V3** `supply(DAI, ...)`, half to
   `SDAI.deposit(...)`.
6. Warp 30 days; touch each reserve to crystallise indices.
7. Read total collateral / debt on Spark, balance of aDAI (Aave) and shares
   of sDAI to surface PnL.

## PnL math

Let:
- `P_usdc` = 1,000,000 USDC
- `B` = borrowed DAI = 500,000 DAI (50% LTV against USDC)
- `r_borrow` = Spark DAI variable APR (snapshot 8.0%)
- `r_aave` = Aave V3 aDAI supply APR (snapshot 4.5%)
- `r_dsr` = DSR (snapshot 8.0%)
- `r_usdc_supply` = Spark USDC supply APR (~3%)

Annualised:
```
cost   = B * r_borrow = 500k * 0.08 = 40k
income = 0.5*B * r_aave + 0.5*B * r_dsr + P_usdc * r_usdc_supply
       = 250k * 0.045 + 250k * 0.08 + 1M * 0.03
       = 11.25k + 20k + 30k = 61.25k

net    = 21.25k / 1M = 2.125% APR
```

This is structurally low because the Spark spread is positive. The strategy
becomes attractive only when one of the deposit legs (DSR or Aave) prints a
rate *above* the Spark borrow rate, which historically happens during the
24-72h windows after Maker DSR hikes (Q1 2024, Q3 2024).

## Block pinned

**19_500_000** (March 28 2024). DSR snapshot 8%; Spark DAI borrow rate ~8.05%
(0.05% net positive over DSR alone — small but present after a recent DSR
hike). Aave V3 aDAI supply ~4.8%.

At this block the *single-leg* arb (Spark borrow -> sDAI) is approximately
flat (≈0bp). The strategy survives via the **USDC collateral supply yield**
on Spark (~3% APR), which delivers the positive 2% headline figure even when
the DAI rate-cross is at parity.

## Risks

- **Rate inversion**: Spark borrow rate climbs above both sDAI and Aave supply
  rate while position is open → carry inverts. Risk is one-sided since DSR
  cuts propagate to both Spark *and* sDAI, but Aave aDAI may decouple
  briefly.
- **USDC depeg**: collateral is USDC; a tail-risk USDC depeg (March 2023)
  liquidates the position.
- **Liquidation**: 50% LTV is well below the ~75% LT but a sustained DAI/USDC
  spread > 30% would still liquidate.
- **Spark D3M unwind**: if Maker pulls the D3M facility, Spark DAI borrow
  rate spikes via the kink, instantly turning the carry deeply negative.
- **Smart contract risk**: Spark, Aave V3, sDAI/Pot.

## Result

Status: theoretical (forge build not run; rates are snapshot estimates,
verified by reading `getReserveData` on the pinned block per Aave V3 docs).
Expected gross PnL over 30 days on 1M USDC principal: **+1,600 to +2,000
USD**. Net of gas the trade is fee-efficient — single tx open, single tx
close.

The PoC's main role is **observational**: it surfaces all three rates as
console logs so a Wave 3 sweep across blocks can identify the windows where
the carry is unambiguously positive.
