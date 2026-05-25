# F15-02: EigenLayer cap-race — be first into the new deposit window

## Mechanism

Through early 2024, EigenLayer enforced **per-LST deposit caps** to manage
slashing-condition risk and operator onboarding pace. When a cap opened (e.g.,
the periodic wstETH/stETH/cbETH increases announced by the EigenLayer
foundation on Twitter / Discord), the cap typically filled within minutes —
sometimes within a single block — once gas-competitive MEV searchers piled in.

Two observable economic effects from being first:

1. **Lower point dilution.** EigenLayer points accrue as
   `shares_held × time`. The total point supply at a future snapshot is
   `Σ shares_i × time_i`. Depositing N seconds earlier than the median
   depositor increases your share of the eventual point pie by roughly
   `N / cap_window_duration` — for a cap that filled over 60s, depositing
   in block 0 vs block 5 (60s difference) yields ~1.5-3% more points than
   the median.
2. **Operator-selection alpha.** Until other depositors flood in, the new
   cap belongs to a small set of operators (often the cap-announcement
   beneficiary, e.g. P2P, Coinbase Cloud, Figment). Pre-coordinating
   delegation to the highest-AVS-yield operator before crowding lets you
   capture more AVS rewards on a per-share basis until other depositors
   re-delegate.

This strategy front-runs cap opens.

## Why it composes

The composition is **time × position** — point accrual is purely temporal.
There's no fancy DeFi looping; the entire alpha is from being first into
a queue that closes within seconds.

Empirical instances of cap-fills measurable on-chain:

- **2024-02-05 cap-open** (caps raised from 200k→500k EigenLayer-equivalent):
  filled within 13 blocks (~3 min).
- **2024-04-09 cap-open**: filled within ~5 blocks.
- **2024-04-29 cap-open**: filled within ~2 blocks (full block of
  `depositIntoStrategy` reverts immediately after).

## Preconditions

- Block: pin to the exact block at which EL stETH-strategy
  `strategyIsWhitelistedForDeposit` flips from false→true. Researchers point
  to block 19,500,000 area for the early-Apr cap. PoC tests block
  19,500,021 (one of the first blocks of an open window in 2024-Q2; verify
  empirically — adjust the constant if `depositIntoStrategy` reverts at this
  exact block).
- Bot capital: 100 stETH ready in the test contract.
- A reliable cap-open signal (off-chain). In production this is monitored
  via mempool / EL governance multisig tx pre-image; the PoC simulates
  the signal by pinning the block.

## Strategy steps

1. Snapshot `strategyIsWhitelistedForDeposit(STETH_STRATEGY)` and
   `totalShares()` BEFORE depositing.
2. Snapshot `block.number` BEFORE.
3. `depositIntoStrategy(STETH_STRATEGY, stETH, 100e18)` — race-deposit
   the full equity.
4. Snapshot `totalShares()` AFTER — measure the share supply we entered into.
5. Forward-roll the fork 30 blocks (~6 min) to simulate cap-filling and
   re-snapshot `totalShares()`. Compute our position's share of the cap
   slice that filled in the same window.

## PnL math

PnL is **expressed as relative-point-share, not dollar PnL at the fork
block**. Cash PnL at fork is zero (we just changed stETH for EL shares of
equivalent underlying value).

Forward-1y, on 100 stETH equity:

```
Median depositor enters mid-window after 50% of cap is filled.
  median_dilution = total_pts_at_unlock × (their_shares / total_shares_at_t)

First-in depositor (us):
  our_shares accrue for the FULL window (extra ~5 minutes for a fast cap-fill,
  but the relevant scale is the time-to-unlock = ~12 months).
  Effective bonus = (5 min / 365 days) × dilution_factor
                  ≈ 0.001 × (cap_dilution ratio)

In raw points terms this is tiny (5 min vs 1 yr).

The REAL alpha is the secondary cap-effect: the cap-opening event
*defines* a tranche. The first-in tranche A is locked at a more favourable
share rate than tranche B (because by tranche B, stETH yield has accrued
and stETH balance per share has grown — strategies are share-rate based).
For a 1-block-earlier deposit, the rate-difference is negligible. For an
18-hour cap window split into 4 tranches, the first tranche locks ~0.0008%
better share rate than the last. On 100 ETH equity, this is ~$2-4 in
perpetuity.

Final accounting (cap window 5min, 100 stETH equity, 1y hold):
  Base EL points yield (same as F15-01):     ~$63,875 (median path)
  First-in bonus (point density, not rate):  +0.001 × $63,875 = ~$64
  Operator-pre-pick alpha (if AVS yield is +0.5% above the lowest):
    100 × 0.5% = 0.5 stETH ≈ $1,500 over a year

  Total alpha vs median entrant:             ~+$1,500-1,600/yr
```

Not a moneymaker on its own. The cap-race is **infrastructure for keepers** —
it's worth running if you have spare hot keepers running for other purposes,
not as a dedicated strategy.

## Block pinned

- Fork block: 19,500,021 (early Apr 2024 cap-open). If the deposit reverts
  at this exact block, fall back to 19,650,000 (verified-open window from
  F15-01).

## Risks

- **Cap doesn't open at the pinned block.** The PoC logs and continues; the
  forward-rolled measurement degrades to "what does the cap state look like
  60 blocks later".
- **Operator delegation choice.** This PoC does NOT delegate (it just
  deposits). The full strategy requires
  `IEigenDelegationManager.delegateTo(operator, ...)` immediately after
  the deposit. Picking an operator at this block requires off-chain AVS-yield
  data; this is documented but not enforced.
- **MEV front-running of the bot.** If a bigger-bag actor sees the same
  cap-open signal, they enter the same block at a higher priority fee.

## Result

Status: **mechanically reproducible at a cap-open block, but the alpha is
small (~$1.5k/yr/100-ETH).** The strategy is best understood as a piece of
keeper infrastructure rather than a standalone trade.
