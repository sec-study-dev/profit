# F01-04: cbETH eMode loop on Aave v3 (historical inverted-rate regime)

## Mechanism
Coinbase's cbETH is a non-rebasing LST whose exchange rate (`exchangeRate()`)
appreciates with Coinbase's staking yield, net of their commission. The
historical accretion rate is **3.0-3.5% APR**, with cbETH typically trading
at a small *discount* to NAV on secondary markets due to Coinbase's
single-issuer custody risk.

Aave v3 lists cbETH and includes it in the **ETH-correlated e-mode category
(id 1)** alongside wstETH, rETH and WETH. The same 93% LTV / 95% liquidation-
threshold rules apply. The thesis is identical to F01-01 — capture
`K * (s - b)` for `K = 1/(1 - LTV)` — but the cbETH leg adds two distinct
sources of alpha relative to the wstETH version:

1. **Discount-to-NAV entry**: a cbETH:ETH spot discount of 50-100 bp at
   the open block lets the strategy enter the leverage stack at a discount
   that mean-reverts toward NAV via the exchange-rate function.
2. **Borrow-rate inversion windows**: during the late-2022 / early-2023
   correlated-asset downturn, Aave's e-mode WETH borrow rate briefly *fell
   below* the cbETH yield by ~150 bp, opening a window of unusually fat
   leveraged carry. The PoC pins a block from such a window.

## Why it composes
Coinbase-as-staker plus Aave-as-money-market composes because cbETH is, in
risk terms, the most centralised of the major LSTs — but Aave's risk
parameters were calibrated assuming Coinbase remains solvent and continues
operating the staking program. As long as that assumption holds, cbETH's
exchange-rate appreciation is a contractually committed yield, and Aave's
e-mode treats it as price-equivalent to ETH. The strategy therefore captures
yield differential while explicitly assuming Coinbase counterparty risk;
this is *not* a free lunch versus wstETH but rather a different point on
the risk-yield curve.

The deeper observation is that the existence of three correlated LSTs in the
same Aave e-mode (wstETH, rETH, cbETH) means a sophisticated operator can
rotate between them block-to-block as borrow-rate-vs-stake-rate dynamics
shift. F01-01, F01-03 and F01-04 together cover the rotation set, and the
PnL block at the chosen historical inversion height shows that *one* of the
three was always the better choice at any given moment — that is the macro
composition argument.

## Preconditions
- Mainnet block where cbETH e-mode is active on Aave v3.
- Block snapshot where Aave e-mode WETH borrow APY < cbETH yield. PoC pins
  block 17_500_000 (June 2023) when this regime held empirically.
- Sufficient cbETH supply cap headroom (cbETH has a tighter supply cap than
  wstETH on Aave).

## Strategy steps
1. Fund principal as WETH.
2. Swap WETH -> cbETH via Curve cbETH/ETH or Uniswap v3 cbETH/WETH 500 bp
   pool (~5 bp swap fee at the size implied by 100 ETH principal).
3. Supply cbETH to Aave, `setUserEMode(1)`.
4. For N rounds:
   a. `borrow` WETH at LTV ~0.88 (buffer below 93% cap given cbETH oracle
      lag tolerance).
   b. Swap WETH -> cbETH on secondary.
   c. Re-supply.
5. After ~5 rounds the position is ~8.3x leveraged.
6. Hold for the carry window.

## PnL math
With historical block parameters:
- `s` = cbETH yield ≈ 0.034
- `b` = Aave variable WETH borrow APY (e-mode) ≈ 0.019 (depressed regime)
- `L` = 0.88 -> `K = 8.33`

```
net_apy = K * s - (K - 1) * b
        = 8.33 * 0.034 - 7.33 * 0.019
        = 0.283 - 0.139
        = 0.144 (~14.4% APY)
```

Per 100 ETH over 30 days: ~`100 * 0.144 * 30/365 = 1.18 ETH` gross.

Additionally, if cbETH spot is at a 60 bp discount at the open block and
mean-reverts to NAV over the holding period, the strategy banks an extra
`K * 0.006 ~= 5%` one-off NAV catch-up, though this is *not* guaranteed
(the discount can widen).

## Block pinned
**17_500_000** (June 2023) — a regime where Aave e-mode variable WETH
borrow APY was depressed to ~1.9% while cbETH yield held at ~3.4%, giving
the widest historical leveraged-carry window for cbETH.

## Risks
- **Coinbase custody / counterparty**: a Coinbase-side staking failure or
  regulatory enforcement could shutter cbETH redemption, collapsing the
  exchange-rate function or the secondary peg.
- **cbETH discount widening**: cbETH frequently trades at -50 to -150 bp
  vs NAV on Curve / Uniswap; a sudden widening triggers an oracle-vs-spot
  mismatch and can mark the position into liquidation territory.
- **Aave supply cap binding**: the cbETH supply cap on Aave has been
  intermittently fully utilised; PoC must check headroom or position-size
  conservatively.
- **Borrow-rate regime reversion**: the inversion that makes this
  particularly fat is regime-specific; in normal markets net carry is
  similar to F01-01.

## Result
Status: theoretical, parameterised to a historical block snapshot
(17_500_000). PoC compiles but does not run; rate measurements are from
contemporaneous Aave dashboards.
Expected PnL: **+1.0% to +1.4% over 30 days** on 100 ETH principal at the
pinned historical block, ~$2.0-2.8k at then-prevailing ETH price ($1.9k).
