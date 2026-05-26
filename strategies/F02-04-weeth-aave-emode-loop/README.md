# F02-04: weETH → Aave V3 eMode → borrow ETH → restake (pure points loop)

## Mechanism
Aave V3 supports **eMode** (efficiency mode), a per-asset-category leverage uplift
that bumps the LTV / liquidation threshold dramatically when collateral and debt
share a price oracle (e.g. both ETH-correlated). For the "ETH-correlated" eMode
category, weETH was added with:

- LTV: **93%** (vs. ~72% non-eMode)
- LT:  **95%**

Strategy: deposit weETH into Aave V3 (eMode), borrow WETH at 93% LTV, unwrap to
ETH, deposit to EtherFi liquidity pool, wrap to weETH, repeat. With on-chain
iterative looping (no flashloan needed for moderate leverage; flashloan helps at
the LTV ceiling) reach ~13x leverage at 93% LTV (1 / (1 - 0.93)).

vs. F02-01 (Morpho flashloan): Aave eMode allows **higher LTV** (93% vs 86%) so
**twice the leverage**, but Aave's WETH variable borrow rate is typically
higher than Morpho's curated market (3-4% vs ~2.5%). Trade-off: more points
notional, slightly tighter cash spread.

## Why it composes
The composition is the simplest possible — no Pendle, no Karak, no flashloan
acrobatics — pure points multiplication via eMode. The leverage formula:

```
points_notional = equity / (1 - LTV) = equity / 0.07 ≈ 14.3x
                  (in practice ~10-12x with safety buffer)
```

EtherFi + EigenLayer point rates × 10-12x leverage = strict winner over spot
weETH holding if the cash spread is non-negative. With WETH borrow rate
~3.2% and weETH-rate yield ~3.1%, the cash spread is **slightly negative**
(~0.1%/yr on the levered notional), but at 12x that's only -1.2% on equity:
acceptable carry-cost for the point-stack uplift.

## Preconditions
- Block: 19,500,000 (mid-March 2024 — weETH listed on Aave V3 with eMode active)
- Aave V3 eMode category "ETH-correlated" includes weETH and WETH
- weETH supply cap not full (in early days frequently was; assume room at this
  block — was raised by governance proposal AAVE-V3.2-019)
- WETH borrow rate ~3.0-3.5%

## Strategy steps
1. Receive 100 WETH equity.
2. Convert to weETH: unwrap → EtherFi deposit → wrap. (~98 weETH at rate 1.02.)
3. `IAavePool.supply(weETH, all, address(this), 0)`.
4. `IAavePool.setUserUseReserveAsCollateral(weETH, true)`.
5. `IAavePool.setUserEMode(1)` — category 1 = "ETH correlated" on Aave V3
   Ethereum mainnet (Aave V3 genesis payload set
   `setEModeCategory(1, 90_00, 93_00, 10_100, address(0), 'ETH correlated')`).
   weETH is enrolled in category 1 alongside WETH / wstETH / cbETH / rETH at
   FORK_BLOCK 19,500,000.
6. Loop iteratively (or one-shot via Aave V3 flashLoanSimple):
   a. Read `getUserAccountData` → `availableBorrowsBase`.
   b. `borrow(WETH, ~90% of available, 2, 0, address(this))`. (Variable rate.)
   c. Convert WETH → weETH (steps 2).
   d. Supply more.
   e. Repeat until 1 / (1 - LTV) ≈ 10-12x.
7. (Optional) Stake any aWeETH receipt tokens — at this block they are not
   stakeable, but **EtherFi credits points based on weETH ownership**, including
   the underlying balance behind aWeETH (per public docs). Verify carefully.

## PnL math
Inputs: 100 ETH equity, 10x leverage, 1-year hold.

```
End state:
  collateral = ~1000 weETH (1020 ETH-equiv at rate 1.02)
  debt       = 900 WETH
  net equity = ~100 ETH

Cash leg (1 year):
  weETH-rate yield = 1020 × 3.1%  = +31.6 ETH
  WETH borrow cost = 900  × 3.3%  = -29.7 ETH
  Net cash carry   = +1.9 ETH ≈ +1.9% on equity ($5700/yr)

Point leg (the thesis):
  EtherFi loyalty (S2-S3 emission): 1020 × 10k pts/ETH/day × 365 = ~3.7B pts
    At post-S1 implied $0.00005/pt: ~$186,000
    At post-S1 lower bound $0.00002/pt: ~$75,000
  EigenLayer rs-pts: 1020 ETH-day/year × 1 ETH-day-per-day
    = 372,300 ETH-days
    At $2/ETH-day historical EIGEN claim: $745,000
    At conservative $0.5/ETH-day: $186,000

  Combined point value @ conservative: $260,000/yr
  Combined point value @ historical-realised: $930,000/yr
```

Outcome (per $300k equity over 1y):
- Cash only: **+$6k** (~+2%)
- Cash + conservative points: **+$265k** (~+90%)
- Cash + historical-EIGEN-FDV points: **+$940k** (~+310%)

## Block pinned
- Fork block 19,500,000 (mid-March 2024)
- Aave V3 weETH-eMode listing tx (TODO verify exact tx-hash; was the AAVE-V3.2-019
  ratify-execute transaction roughly mid-Feb 2024).
- Aave V3 Pool address: `Mainnet.AAVE_V3_POOL` (`0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`)

## Risks
- **Supply cap.** weETH supply cap was repeatedly hit. If full at execution
  block, strategy fails to add collateral — no graceful degradation.
- **eMode category change.** Aave governance has retroactively narrowed eMode
  asset lists. A future change could force position to ~72% LTV — instant
  liquidation risk.
- **Borrow rate spike.** Aave WETH-borrow rate has touched 8-10% briefly during
  unwinds. At 10× leverage, even a 1-month spike is -3% on equity.
- **weETH/ETH oracle.** Aave uses a Chainlink weETH/ETH proxy ultimately tied
  to EtherFi's `getRate()`. A bug or stale rate could trigger unfair liquidation.
- **Slashing pass-through.** weETH NAV reflects EigenLayer/AVS slashing
  proportionally; a slashing event reduces collateral.
- **Cash carry inversion.** At equilibrium, weETH-rate ≈ WETH-borrow; structural
  arbs flatten the spread.
- **Points dilution / clawback** — same as F02-01/02/03.

## Result
Status: **theoretical**. The on-chain cash mechanics are reproducible and
modest-margin; the entire alpha is the point-stack capture.

PnL range (1y, 100 ETH equity = $300k):
- Cash only: **+$3-10k** (1-3%)
- Cash + realised point claims (range): **+$100k-$1M** (33-330%)
- Worst case (depeg + liquidation): **-$30k** (capped by 95% LT)
