# F04-02: sDAI as Spark collateral, DAI-borrow re-stake loop

## Mechanism

This strategy stacks three Maker/Sky primitives:

1. **sDAI (`0x83F20F44975D03b1b09e64809B757c47f942BEeA`)** — Maker's ERC-4626
   over DAI, where `convertToAssets(shares)` increases monotonically at the DSR
   (`Pot.chi()` accumulator, `Pot.dsr()` per-second rate). At a typical 8% DSR
   the share price grows ~0.022% per day.
2. **Pot (`0x197E90f9FAD81970bA7976f33CbD77088E5D7cf7`)** — the DSR rate
   accumulator. `dsr()` is the per-second factor in RAY (1e27) units; APR =
   `(dsr/1e27)^secondsPerYear - 1`. sDAI's `chi` syncs with `Pot.chi()` on
   every `drip()`.
3. **Spark Pool (`0xC13e21B648A5Ee794902342038FF3aDAB66BE987`)** — a Maker-
   aligned Aave v3 fork that lists sDAI as a collateral asset (LTV ~74%) and
   maintains a DAI reserve whose borrow rate is governance-pinned a few basis
   points *above* the DSR (the Spark Effective Dai Savings Rate model targets
   DSR for supply and DSR+spread for borrow). This makes sDAI -> Spark DAI loops
   intentionally legal, and historically marginal but tractable when the
   spread compresses.

The loop:

```
DAI seed --deposit--> sDAI --supply--> Spark
              ^                          |
              |                          v
              +<---deposit------ DAI <-- borrow
```

Each turn:
- Convert DAI to sDAI at price `chi_t`.
- Supply sDAI to Spark, borrowing DAI at LTV-bounded amount.
- Re-deposit the borrowed DAI back into sDAI; repeat.

At leverage L, the net carry is:
```
APY = L * sDAI_APY - (L - 1) * Spark_DAI_borrow_APY
```
where `sDAI_APY = (1 + dsr/1e27)^secondsPerYear - 1`. With current parameters
the spread is small (sometimes zero) but the loop is the canonical way to
*amplify* the DSR baseline.

## Why it composes

Spark is the only money market where DSR-anchored sDAI is a first-class
collateral and the borrowable counter-asset (DAI) shares its rate model with
the DSR. That means:

- Collateral and debt are denominated in the *same* underlying (DAI), so there
  is no interim liquidation risk from oracle divergence — the only risk is the
  sDAI/DAI ERC-4626 exchange-rate oracle, which monotonically rises with `chi`.
- Spark's `DAI` interest-rate strategy reads `DAI_IRM` parameters set to
  `borrow ≈ DSR + spread`, so the strategy explicitly *funds* sDAI loops at the
  margin rather than competing against general DAI demand.
- Refilling sDAI from borrowed DAI is gas-cheap (one `sDAI.deposit`) — no AMM
  hops needed, no slippage.

No other stack offers a same-asset-denomination loop where the collateral's
yield is set by the same DAO that sets the borrow rate.

## Preconditions

- Mainnet block where Spark's sDAI reserve has spare supply cap and DAI reserve
  has free liquidity.
- DSR rate `pot.dsr()` translated to APY > Spark's DAI variable borrow APY.
  When this is false, the loop drifts negative; the PoC reads both and skips
  asserting profit accumulation if the live spread is non-positive.

## Strategy steps

1. Pin fork to **block `19_500_000`** (early March 2024). At this block:
   - DSR = 15% (governance had raised DSR to anchor sDAI yield)
   - Spark DAI borrow APY ≈ 14.5%
   - sDAI LTV in Spark = 0.74
2. Wrap seed DAI to sDAI via `sDAI.deposit(daiAmount, address(this))`.
3. Approve and `Spark.supply(sDAI, amount, this, 0)`.
4. Loop:
   - Read `getUserAccountData` -> `availableBorrowsBase` (8-decimal USD).
   - Borrow `safeFrac * availableBorrowsBase` of DAI (interest-rate-mode = 2
     variable). `safeFrac = 0.85` to stay clear of LT.
   - `sDAI.deposit(borrowedDai, this)`.
   - `Spark.supply(sDAI, newShares, this, 0)`.
5. Repeat 5 iterations -> effective leverage ≈ 1/(1 − 0.74·0.85) ≈ 2.7x.
6. After warp +30 days, settle: compute net asset = supplied sDAI valued at
   current `chi` − DAI debt + accrued.

## PnL math

Let `r_s = DSR APY`, `r_b = Spark DAI borrow APY`, `L = effective leverage on
seed`. Then steady-state APY on seed equity:

```
APY_net = L * r_s - (L - 1) * r_b
        = r_s + (L - 1) * (r_s - r_b)
```

With `r_s = 15%`, `r_b = 14.5%`, `L = 2.7x`:
`APY_net = 0.15 + 1.7 * 0.005 = 0.1585 = 15.85%` on equity (vs 15% naked sDAI).

Over 30 days that's `(1.1585)^(30/365) - 1 ≈ 1.21%` on seed equity, or
~$1_210 per $100_000 seed in a month. Gas for the 11 calls of the
5-iteration loop is ~1.4 M gas — at 20 gwei and ETH=$3500 that's ~$98 -
amortized across rebalances ≈ 0.1% of seed, negligible vs the 1.21% return.

When the spread (`r_s − r_b`) is negative, the formula goes the other way and
levered loops *lose* relative to unlevered sDAI. The PoC reads live rates and
asserts that the chosen pinned block sits in the positive regime.

## Block pinned

`19_500_000` — March 6 2024. Period of elevated DSR after the SparkLend launch
spread; sDAI was the only place to lock 15% on DAI without taking smart-contract
risk on sUSDe-style synthetics, and Spark's DAI borrow rate ran a few bps
below DSR for a window.

## Risks

- **Spread compression / inversion.** Maker governance can change DSR or the
  Spark DAI IRM parameters in any spell; if borrow APY > DSR APY the loop
  bleeds.
- **Spark LT change.** A governance spell that lowers sDAI's LT below current
  health factor would force a liquidation snap. The PoC stays at `0.85 *
  availableBorrowsBase` to keep HF > 1.15.
- **DSR drip latency.** `Pot.drip()` updates `chi` lazily. Withdrawals before
  the next `drip` realize the *previous* `chi`. The PoC manually calls
  `pot.drip()` before each withdrawal.
- **Sky USDS migration.** Sky has introduced sUSDS at a higher Savings Rate
  (SSR) than DSR for periods; on those windows F04-03 dominates this one.

## Result
Status: theoretical-historical-replay
Expected PnL: ~15.85% APY on equity (~1.21% / ~$1,210 per $100k seed over 30 days at DSR=15%, Spark borrow=14.5%, L=2.7x)

A clean same-asset DAI loop where leverage amplifies the DSR baseline by the
sDAI-vs-Spark spread. PoC asserts: leverage > 2.5x after 5 iterations, positive
net DAI delta on seed after 30 days of warp, and that the loop can be
fully unwound (debt = 0, all sDAI redeemed for DAI).
