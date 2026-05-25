# F02-01: weETH leveraged restake via Morpho flashloan loop

## Mechanism
EtherFi's eETH is a rebasing LST representing staked ETH that is auto-restaked into
EigenLayer; weETH is the non-rebasing wrapper whose `getRate()` monotonically grows.
Beyond the cash yield (~3.0-3.3% on the underlying stake) every weETH held earns:

- **EtherFi loyalty points** (multiplier-tracked off-chain — primary airdrop driver)
- **EigenLayer restaking points** (`points-per-weETH-per-second`, redeemable for EIGEN claims)

Morpho Blue runs an isolated `weETH/WETH` market (Gauntlet-curated, LLTV typically
86%–94.5%). The loop uses Morpho's zero-fee `flashLoan()` to bootstrap N rounds of
mint-and-collateralise in a single transaction, so the loop's effective leverage is
limited by the LLTV, not by iteration gas.

## Why it composes
Cash carry alone is barely positive (weETH-rate ≈ 3.1%, WETH borrow ≈ 2.5%, so net
spread ≈ 0.6% on the base notional). The thesis is **point multiplication**:

```
points_per_$ ≈ point_emission_rate × leverage_factor
leverage_factor = 1 / (1 - LTV) (at max safe LTV, ~5x at 80%, ~10x at 90%)
```

Both EtherFi and EigenLayer score points on the notional weETH held, **not** on
net equity. Since the borrower keeps the entire weETH stack as collateral, points
accrue on the levered position. At the EIGEN airdrop's implied $1.5-$3 per
EigenLayer "restaked-ETH-day" historical valuation, the points yield dominates the
~0.6% cash carry by 5-15×.

## Preconditions
- Block: 19,200,000 (Feb 2024 — after the weETH/WETH Morpho market launch and
  after EtherFi season-1 boost halving; LRT season-2 in progress)
- Morpho weETH/WETH market exists with 86% LLTV (Gauntlet config)
- weETH on-chain rate ≥ 1.018 ETH/weETH (about 4 months of carry)
- WETH borrow rate ~2.0-2.6%, weETH supply share ~0.5%

## Strategy steps
1. Receive 100 WETH from user (the equity tranche).
2. Call `IMorpho.flashLoan(WETH, 400 ether, data)` for 4× notional.
3. Inside callback: total 500 WETH on hand.
4. Unwrap to ETH; deposit to `IEtherFiLiquidityPool.deposit()` → receive 500 eETH (1:1).
5. Approve weETH, call `IWeETH.wrap(500e18)` → ~491 weETH (at rate ≈ 1.0186).
6. `IMorpho.supplyCollateral(weETHMarket, 491e18, ...)`.
7. `IMorpho.borrow(weETHMarket, 400 WETH, ...)` to repay the flashloan principal.
8. Approve Morpho the 400 WETH and return inside the same callback (zero fee).
9. Exit (after points accrual epoch) by unwinding via Morpho's freeloan again or
   via 1inch swap weETH→WETH on the secondary market.

## PnL math
For 100 ETH equity, 5× leverage, 1-year hold:

```
Cash leg:
  collateral = 491 weETH ≈ 500 ETH-equiv
  debt       = 400 WETH
  net equity = 100 ETH
  weETH yield      = 500 × 3.1% = 15.5 ETH/yr
  WETH borrow cost = 400 × 2.5% = 10.0 ETH/yr
  net cash carry   = 5.5 ETH/yr ≈ +5.5% on equity
  (at ETH=$3000: ~$16,500/yr cash)

Point leg (speculative):
  EtherFi loyalty: 10k pts/ETH/day × 500 × 365 = 1.83B points
  Assumed $/pt (post-airdrop heuristic, conservative)  : $0.00005
  → ~$91,000/yr

  EigenLayer rs-pts: 1 ETH-day × 500 × 365 = 182,500 ETH-days
  EIGEN airdrop priced 1 ETH-day @ ~$2.0 (S1 actual)
  → ~$365,000/yr (HIGH variance: depends on EIGEN supply released)
```

Combined estimate (year): **+$16k cash + $90k-450k expected airdrop value** per
$300k equity = **+35-150% IRR** if points materialise; ~5% if they don't.

## Block pinned
- Fork block 19,200,000 (mid Feb 2024)
- No specific reference tx; this is a documented EtherFi-strategist pattern used by
  Re7, Gauntlet Pinwheel, and Affine vaults around that period.

## Risks
- **Points dilution.** Both EtherFi and EigenLayer can (and have) reduced point
  rates retroactively when TVL surged. Season-1 boost halving cost ~50% APR.
- **Slashing.** EigenLayer AVS slashing live since 2024; chain risk to weETH NAV.
- **Rate inversion.** WETH borrow rate can spike above weETH-yield if a major
  unwind happens; need to unwind quickly.
- **Depeg.** Morpho oracle prices weETH/WETH off ETH-rate; if secondary trades
  ≪ rate, an exit via DEX realises a loss on the principal.
- **LLTV reduction.** Gauntlet has lowered LLTVs on stressed markets — could
  force a partial unwind.

## Result
Status: **theoretical** (cash carry is small but on-chain reproducible; points
PnL is by definition off-chain forward-looking).

PnL range (1y, $300k notional / 100 ETH equity):
- Cash only: +$10k to +$22k
- Cash + realised points (EtherFi S2 + EIGEN claim at FDV ranges): **+$100k to +$500k**.
