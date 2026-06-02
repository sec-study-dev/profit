# B02-03: ankrBNB `ratio()` vs PCS v3 spot single-pool flash arb

## Mechanism
Ankr's ankrBNB exposes a peculiar exchange-rate function: `ratio()` returns
the number of **ankrBNB shares per 1 BNB**, scaled to 1e18. So the BNB value
of `n` ankrBNB is computed as `n * 1e18 / ratio()` (note the inverted
relation vs slisBNB/BNBx, which return BNB-per-share). This inversion makes
the strategy subtly different from B02-01/02 and is a common bug source for
naive arb bots — which is exactly why the dislocation persists.

The ankrBNB/WBNB PCS v3 pool quotes ankrBNB in WBNB without knowing the
true `1/ratio()`-implied price. When the pool's mid drifts away from
`1e18 / ratio()` by more than the pool fee + flash fee, a single-tx round
trip captures the difference.

Atomic flow:

1. PCS v3 single-pool `flash(WBNB notional)` from the ankrBNB/WBNB pool's
   sibling fee tier (so we can re-enter the *target* pool for the swap).
2. Swap WBNB -> ankrBNB on the target ankrBNB/WBNB pool.
3. Compute fair value via Ankr's view: `bnbValue = ankrOut * 1e18 / ratio()`
   *or* the convenience wrapper `sharesToBonds(ankrOut)`.
4. Compare to flashed WBNB + fee. Profitable when `bnbValue > flashed + fee`.
5. Close the loop one of two ways:
   - **Atomic**: swap ankrBNB back to WBNB on a *different* venue (PCS v2
     ankrBNB/WBNB pair, or the PCS v3 0.25% fee tier).
   - **Stake-manager close (modelled)**: Ankr exposes a redeem path
     through its bond contract; not all blocks support instant burn so
     PoC defaults to the atomic two-DEX close.

This PoC implements the **two-fee-tier round trip** on PCS v3: flash from the
500-bp tier, swap in the 100-bp tier, close in the 2500-bp tier.

## Why it composes
- **PCS v3 flash from sibling tier**: same pair, different fee → arbitrary
  inter-tier mispricing is naturally captured.
- **Ankr ratio() inversion gotcha**: `ratio` returns *shares-per-BNB* rather
  than *BNB-per-share*. Pricing PoCs/bots that hard-code the slisBNB
  convention misprice ankrBNB, leaving spreads on the table.
- **Three liquidity venues**: PCS v3 100 bp (deep, retail), PCS v3 500 bp
  (LP rotation), PCS v3 2500 bp (yield-seeking LPs). All quote ankrBNB
  slightly differently because of fee-tier reserve imbalance.

## Preconditions
- ankrBNB/WBNB pools exist on ≥2 fee tiers. (TODO verify: PCS v3 shows
  100, 500, 2500 tier pools historically.)
- ankrBNB `ratio()` returns a sane value (~0.92e18 at typical ratios since
  ankrBNB > BNB after months of yield).

## Strategy steps
1. Resolve flash pool (500 bp). Encode `flash(notional)` callback.
2. In callback:
   a. Use PCS v3 router to swap WBNB -> ankrBNB on the **100-bp pool**.
   b. Read `ratio = IankrBNB(ankrBNB).ratio()` and assert
      `ankrOut * 1e18 / ratio > notional + flashFee`.
   c. Swap ankrBNB -> WBNB on the **2500-bp pool** for the exit leg.
   d. Repay flash from the combined exit + buffer.
3. PnL is the residual WBNB after flash repayment.

## PnL math
Let `P_in = 100-bp pool quote` (ankrBNB per WBNB) and
`P_out = 2500-bp pool quote` (WBNB per ankrBNB). Fair value implied by
ratio: `1 ankrBNB = 1e18 / ratio() BNB` (e.g. ratio = 0.92e18 → 1.087 BNB).

Round trip: `ankr = N * P_in`; `wbnb_back = ankr * P_out = N * P_in * P_out`.
Gross = `N * (P_in * P_out - 1)`. Fees: 100 bp pool eats 0.01%, 2500 bp pool
eats 0.25%, flash eats 0.05% → ~31 bp friction.

Realistic:
- Inter-tier dislocation ~5-50 bp depending on epoch.
- At 50 bp net (after friction), `N = 1000` → ~5 WBNB ≈ $3,000.
- Quiet weeks: 5-10 bp net → $300-600.

## Block pinned
- `FORK_BLOCK = 45_000_000` (placeholder). **TODO**: pin a block right after
  a large ankrBNB mint/burn where the 2500-bp tier hasn't rebalanced yet.

## Risks
- **ratio() inversion mistake**: if you compute `ankrOut * ratio() / 1e18`
  you'll under-value ankrBNB by ~17%. The PoC uses the correct
  `ankrOut * 1e18 / ratio()` formula and double-checks with
  `sharesToBonds(ankrOut)`.
- **Fee tier may not exist**: not every ankrBNB pair has 2500 bp tier with
  meaningful TVL. The PoC falls back to PCS v2 if PCS v3 2500 has no code.
- **Whale LP**: a single LP rebalancing across fee tiers can collapse the
  spread mid-block.

## Result
- Status: **theoretical / offline-first**.
- Expected PnL: **+$200 to +$3,000 per 1000 WBNB** depending on inter-tier
  spread.
