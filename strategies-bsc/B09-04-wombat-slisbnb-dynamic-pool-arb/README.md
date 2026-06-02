# B09-04: Wombat slisBNB/BNB dynamic-pool weight-skew arb

## Mechanism
Wombat operates LST sidecar pools alongside the Main Pool. The slisBNB/WBNB
sidecar uses the **same dynamic asset weight invariant**, but with two key
differences vs the stables Main Pool:

- **Anchor token is "exchange-rated"**, not pegged. Wombat's LST pools track
  the slisBNB <-> BNB internal exchange rate (the same rate B02-01 uses from
  `IListaStakeManager.convertSnBnbToBnb`). The pool's `cov` interprets
  liabilities in BNB-equivalent units, not raw token units.
- **Skew direction is asymmetric**: slisBNB holders systematically *redeem*
  to BNB whenever the Lista queue is short, draining the BNB side of the pool
  and pushing `cov_BNB` < 1 / `cov_slisBNB` > 1. That makes BNB-into-pool
  swaps (BNB->slisBNB) extra cheap, while slisBNB-out swaps are expensive
  beyond the trivial size.

The arb has two legs that exploit the **gap between Wombat's quote and the
Lista internal exchange rate** (the canonical fair value for slisBNB):

1. Pre-funded WBNB notional `N`.
2. `Wombat.swap(WBNB, slisBNB, N)` -> receive `S` slisBNB.
3. Compare `S` against `S* = N / convertBnbToSnBnb(N)` (the rate-fair amount).
4. If `S > S* * (1 + threshold)`, the pool over-paid (because BNB was
   under-allocated) and the position is profitable when held to the next
   `slisBNB.compoundRewards` tick, which lifts the internal rate.

An alternative atomic closeout exists when the slisBNB/BNB PCS v3 pool prices
in the opposite direction: round-trip slisBNB back to BNB on PCS v3 within
the same tx. The PoC defaults to the **rate-fair-value** comparison and lets
the slisBNB position be valued at the internal rate (mirrors B02-01).

## Why it composes
- **Wombat dynamic weight on a non-1:1 anchor**: stress-tests Wombat's
  re-scaling logic. When Lista's internal rate jumps after a reward sync,
  Wombat's `liability` accounting takes a few blocks to reflect it; in that
  window the pool quote is conservative and pays bonus to BNB depositors.
- **Lista internal rate as oracle**: same source-of-truth pattern used in
  B02-01, allowing direct PnL marking.
- **Dual-exit (atomic vs queued)**: same as B02-01, the position can be
  closed via PCS v3 atomically or via Lista's unbond queue at the internal
  rate.

## Preconditions
- Wombat slisBNB/WBNB sidecar pool exists. **TODO verify**: this is *not*
  the same address as `WOMBAT_MAIN_POOL`. A correct PoC needs the sidecar's
  own pool address (placeholder used; falls back to a quote against the Main
  Pool if slisBNB is registered there as a curiosity asset).
- Lista StakeManager `convertSnBnbToBnb` returns a rate > 1.07 (i.e. post-2024
  block).
- WBNB notional <= 25% of the pool's BNB-side `cash`.

## PnL math
At `cov_BNB = 0.88`, `cov_slisBNB = 1.12` (typical post-redemption-queue state):

- Internal rate: 1 slisBNB = 1.078 BNB.
- Fair `S* = N / 1.078`. For `N = 1000 WBNB`: `S* = 927.6 slisBNB`.
- Wombat quote pays ~12 bp bonus on BNB depositors -> `S = 928.7 slisBNB`.
- Marking `S` at internal rate: `S * 1.078 = 1001.2 BNB-equivalent`.
- Gross profit: 1.2 BNB ≈ $720 @ $600/BNB on a $600k notional. Net of gas
  (sub-$1): essentially the same.

Realistic dislocations:
- Tight market: 2-5 bp bonus -> $120-$300 per 1000 WBNB.
- Post-redemption-queue dump: 10-20 bp -> $600-$1,200.
- Validator-slash rumor: 40+ bp (Wombat quote way below fair) but slisBNB
  carries tail risk in that scenario.

## Block pinned
- `FORK_BLOCK = 45_800_000` (placeholder). **TODO** verify a block where
  Wombat slisBNB pool is skewed `cov_BNB < 0.9`.

## Risks
- **Wrong pool address**: PoC defaults to the slisBNB sidecar address; if
  stale, the on-fork branch reverts and only the offline path runs.
- **Internal rate stale**: if `convertSnBnbToBnb` is called at a block before
  the daily reward sync but the swap is computed after, the marking will be
  slightly conservative. Not a strategy-breaking error.
- **Wombat haircut**: governance can lift the LST-pool haircut from its
  default 5 bp; PoC asserts the actual haircut is consistent with assumption.
- **slisBNB peg risk**: slisBNB has no on-chain hard peg; in stress the
  internal rate could decouple from market price (B02-01 documents this).

## Result
- Status: **theoretical / offline-first**.
- Expected PnL: **+$200 to +$1,500 per 1000 WBNB notional** at typical
  dislocations, valued at the Lista internal rate.
