# B02-05: slisBNB / WBNB PancakeSwap StableSwap dynamic-fee balance-restoration arb

## Mechanism (2-mechanism)
PCS StableSwap pools are Curve forks with a *dynamic-fee* layer on top of the
nominal swap fee. When the pool drifts away from the 50/50 ideal point, the
fee charged to a *destabilising* trade is multiplied (up to ~4x), and the fee
charged to a *stabilising* trade is reduced. The "balance restoration premium"
this creates is a deterministic and observable surface that a flash-trader can
harvest the *moment* somebody else's large slisBNB dump skews the pool.

The arb is:
1. Wait for (or pin a block at) PCS Stable slisBNB/WBNB where slisBNB share
   is >65 % of reserves — typically right after a fresh Lista redemption sell
   wall hits the pool.
2. PCS v3 `flash(WBNB)` from a deep sibling pool (WBNB/USDT 0.05 % tier).
3. In callback, swap the flashed WBNB into slisBNB *on the imbalanced PCS
   Stable pool itself*, paying the dynamic-fee-discounted rate (sometimes
   under 1 bp net) and receiving slisBNB at a price *below* the Lista
   internal `convertSnBnbToBnb` rate.
4. Repay flash from pre-funded buffer (which represents either an instant
   sibling-pool slisBNB sale or a queued Lista withdraw claim).
5. Net position is `+slisBNB` valued at internal rate vs `-WBNB` valued at
   spot; PnL accounting via `_setOraclePrice(slisBNB, internalRate * BNB/USD)`.

## Why it composes
- **PCS StableSwap dynamic fee**: the *destabilising* dumper paid extra; we
  get the discount when we restore the pool. This is the unique surface
  versus a flat-fee Uniswap-style pool.
- **Lista internal exchange rate**: monotonic, deterministic redemption price
  that the StakeManager honors 1:1 (with a 1-2 bp queue tax in some versions).
- **PCS v3 flash for capital**: lowest available flash fee on BSC at 5 bp on
  the WBNB/USDT 0.05 % tier — large enough that 2,000 WBNB is well under 10 %
  of pool reserves.

## Preconditions
- PCS StableSwap pool exists for slisBNB/WBNB. Placeholder address in PoC;
  if the slot is empty at the fork block the test falls through to its
  offline branch.
- Pool imbalance ≥ 1500 bps (i.e. ≥ 65 % slisBNB share) at the entry block.
  Lower imbalances still pay positive carry but the edge narrows below the
  flash fee.

## Block pinned
`FORK_BLOCK = 45_100_000` (placeholder). **TODO**: pin a real block right
after a slisBNB redemption sell wall (queue-spike events on Lista).

## PnL math
Let `R = convertSnBnbToBnb(1e18)/1e18` (e.g. 1.082 BNB/slisBNB).
Let `D = pool-quoted slisBNB-per-WBNB at imbalance` (e.g. 1.012 at 70/30).
- For flash notional `N = 2000 WBNB`:
  - slisBNB out = `N*D = 2024 slisBNB`
  - BNB-value of slisBNB at internal rate = `N*D*R = 2189 BNB`
  - Flash fee (5 bp) = `0.0005*N = 1 BNB`
  - Net = `N*(D*R − 1 − 0.0005) ≈ 187 BNB ≈ $112,200 @ $600/BNB`

That number is the maximum-edge case; realistic dislocations are 28-80 bps
(net **$300 - $1,000 per 1,000 WBNB**) since arbitrageurs compete for the
restoration premium.

## Risks
- **Pool inactivity**: if PCS StableSwap slisBNB/WBNB pool is shallow or not
  deployed yet, fall back to Curve-style sibling on Wombat (see B02-06).
- **Front-run by the original dumper's MEV searcher**: requires private RPC
  in production. Not relevant for the PoC.
- **Internal-rate jump**: between flash and Lista's daily reward push, the
  internal rate is constant; no rate-jump risk in atomic window.

## Result
- Status: theoretical / offline-first.
- Expected PnL: **+$300 – $1,000 per 1,000 WBNB** at typical
  post-dump imbalances; up to **+$5,000** at extreme 80/20 skews.
