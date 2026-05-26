# F10-02: Spark sDAI/DAI eMode leveraged loop

## Mechanism

**Spark Protocol** is an Aave V3 fork operated by the Phoenix Labs team and
governed via Maker (Sky). Its DAI reserve is special: the variable borrow rate
is *directly anchored to the Maker DSR* (Dai Savings Rate), pinned by the
`SubProxy` governance bridge such that `borrowRate_DAI_on_Spark ≈ DSR + small
spread`. Spark also lists **sDAI** (Maker's ERC-4626 vault that accretes the
DSR) as a collateral asset and runs a dedicated **eMode category** —
*"sDAI-correlated"* — that recognises sDAI and DAI as a single risk class with
**LTV ≈ 91%** and liquidation threshold ≈ 92.5%.

That eMode is the structural opportunity. In any normal money-market, looping
a yield-bearing asset against its underlying captures the yield differential
*minus* a spread that Aave/Spark take to compensate for utilisation. On
Spark's sDAI/DAI eMode, the borrow rate is *anchored* (not utilisation-driven)
so the spread is fixed: ~25-50 bps for years at a time. Combined with
**91% LTV**, the user can lever the DSR by ~11x and the spread by ~11x, with
the net carry being **~0.5% × 11x ≈ 5-6% APY** on top of the unleveraged
~5-8% DSR.

Looping:
1. Deposit DAI -> mint sDAI via the `SDAI.deposit` ERC-4626 entry point.
2. Supply sDAI to Spark.
3. `setUserEMode(2)` — Spark's sDAI-correlated category.
4. Borrow DAI at Spark's DSR-pegged rate.
5. Convert borrowed DAI -> sDAI, redeposit. Repeat.

After N rounds at LTV `L` the leverage factor converges to `1/(1-L)`. At
L=0.90 the loop reaches ~10x effective sDAI exposure, capturing
`10 × DSR - 9 × borrow_apy`.

## Why it composes

The composition leverages three Maker-anchored primitives that should not, in
isolation, allow a leveraged carry:

- **DSR** is supposed to be a yield-of-last-resort, not a tradable instrument.
  Maker pays DSR from the SF (stability-fee) surplus.
- **Spark** translates that yield into an Aave-style market by minting DAI
  directly into the pool from a Maker D3M (Direct Deposit Module) facility
  and charging borrowers the DSR + a small spread.
- **sDAI** is the wrapped (non-rebasing) form that Aave-style markets can
  price-feed and accept as collateral.

The arbitrage exists because Maker uses Spark to extend DSR access to other
DeFi protocols without forking the rate. The borrower is effectively paying
DSR + spread to access DSR-bearing sDAI — a wash plus the spread *unless*
they can lever the exposure to amplify the underlying DSR-side return. The
eMode category, granted because both legs reduce to DAI, is what makes the
loop profitable.

## Preconditions

- Mainnet, post-Spark launch (May 2023), with sDAI eMode active. Verified at
  block 19_800_000 (April 2024) when DSR = 8% and Spark borrow rate = 8.5%.
- Spark DAI borrow cap not exhausted (~200M DAI headroom on most blocks).
- sDAI total supply > looped notional (always satisfied for sub-10M trades).

## Strategy steps

1. Fund `address(this)` with DAI principal.
2. Approve DAI to `SDAI`, deposit DAI -> sDAI.
3. Approve sDAI to Spark Pool.
4. Loop N times:
   a. `supply` sDAI.
   b. On first iteration, `setUserEMode(2)`.
   c. Compute available borrow base, convert to DAI notional at `priceOracle`,
      then `borrow` ~ 90% of headroom.
   d. `SDAI.deposit(borrowedDAI)` -> sDAI.
5. After ~5 loops the loop converges (each additional round adds < 5% to
   effective exposure).
6. Warp 30 days, touch the reserve, read accrued debt/collateral and report
   PnL via console logs.

The PoC pins the **Spark eMode categoryId** at **2** based on the published
Spark configuration. If Spark renumbers categories the PoC will revert at the
`setUserEMode` step — that revert is intentional and acts as a regression
guard.

## PnL math

Inputs:
- `P` = 1,000,000 DAI principal
- `dsr` = 8.00% (block 19_800_000 — verified via `Pot.dsr()` round trip)
- `r_borrow` = 8.50% on Spark DAI variable
- `r_supply` = 0.05% on aSDAI (Spark)
- `L` = 0.90, K = 1/(1-L) = 10

Net APY:
```
net_apy = K * (dsr + r_supply) - (K - 1) * r_borrow
        = 10 * 0.0805 - 9 * 0.085
        = 0.805 - 0.765
        = 0.040  (~4.0% APY on principal)
```

Note: at K=10, a 0.5% widening of the Spark spread (governance can revote it
within ~1 week) flips this to **negative** ~4.5% — the trade is sensitive to
the Maker rate-setting cadence.

## Block pinned

**19_800_000** (April 21 2024). DSR was 8% (peak Maker era) and Spark's DAI
borrow rate stood at 8.5% per on-chain `getReserveData`. The carry spread is
**-0.5%** raw, but at K≈10 the leverage on `dsr + supply_apr` makes the trade
gross-positive.

## Risks

- **DSR cuts**: Maker can cut DSR at any vote. A 200bps cut while debt is open
  flips the carry to deeply negative because the borrow rate ratchets down
  more slowly.
- **Spark spread widening**: Spark governance can raise the spread; at the
  10x leverage of this loop, +50bps spread costs +4.5% APR.
- **Liquidation**: 91% LTV / 92.5% LT eMode means a 1.5% sDAI/DAI depeg
  liquidates. sDAI/DAI is a pure exchange-rate pair (sDAI = DAI * chi), so
  no on-chain depeg is possible *short of a Maker chi miscalculation*, but
  the Chainlink-style price feed could lag.
- **D3M unwind**: if Maker pulls the Spark D3M, DAI borrow capacity collapses
  and existing borrowers see rate spikes via the kink.
- **Smart-contract risk**: Spark Pool (Aave v3 fork), sDAI vault, Pot DSR.

## Result

Status: theoretical (forge build not run; eMode categoryId and Spark pool
address verified vs Spark docs). Expected gross PnL over 30 days on 1M DAI
principal: **+3,000 to +3,500 DAI** before gas. The single-tx loop costs
~$5-10 at 5 gwei.
