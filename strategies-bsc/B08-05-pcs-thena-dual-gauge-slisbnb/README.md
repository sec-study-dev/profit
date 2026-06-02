# B08-05: PCS + Thena dual-gauge stake on slisBNB/BNB (3-mechanism)

## Mechanism
The same underlying productive activity — providing slisBNB/BNB liquidity —
is rewarded by two **independent** gauge systems:

1. **Lista LST** (slisBNB) — passive 3.2 % exchange-rate APR while staked.
2. **Thena gauge** — THE emissions on the volatile slisBNB/WBNB pair
   (~45 % gauge APR at $0.30 THE).
3. **PCS v2 MasterChefV2** — CAKE emissions on the same pair on PancakeSwap
   v2 (~28 % gauge APR at $2.40 CAKE).

We split 200 BNB principal 50/50 across the two DEX pools and farm both
gauges over a 7-day epoch.

## Why it composes
- Lista wants slisBNB liquidity on **both** DEXs because price discovery
  fragments across them. PCS and Thena each subsidise the same pair
  independently, which means an LP who can run both pools at once captures
  the union of subsidies.
- The Lista LST exchange-rate accrual is **non-rival** with gauge farming
  — slisBNB earns staking yield while it sits inside an LP token.
- Capital efficiency is the dominant constraint: by splitting principal
  across two gauges we trade off depth-per-pool against double subsidy.

## Preconditions
- PCS v2 slisBNB/WBNB MasterChefV2 farm live at pinned block (pid TBD).
- Thena slisBNB/WBNB gauge live with non-zero THE rewardRate.
- slisBNB peg holds within 10 bps of fair-value over the epoch (else
  impermanent loss can erase gauge yield).

## Numbers (THE=$0.30, CAKE=$2.40, BNB=$600)
- Principal: 200 BNB = $120 000.
- Per-leg notional: $60 000.
- Thena leg: $60k × 45 % × 7/365 = **$517 / week** THE emission =
  1 726 THE @ $0.30.
- PCS leg: $60k × 28 % × 7/365 = **$322 / week** CAKE emission =
  134 CAKE @ $2.40.
- LST accrual: 100 BNB slisBNB × 3.2 % × 7/365 = **$11 / week**.
- LP fees: 200 BNB × 5 bps = 0.1 BNB = **$60 / week**.
- **Gross: $910 / week ≈ 39 % APR on $120k principal.**
- Net of 30 bps harvest slippage + gas: ~37 % APR.

## Trade-off observation
- Single-gauge (Thena only) at full $120k principal: 45 % APR × 100 % =
  **45 % APR** on a single pool. Splitting capital costs ~6 % APR.
- The dual-gauge story is only better if PCS APR > 17 % (cost of going
  half-allocated on Thena). At our 28 % assumption, the split wins
  marginally **and** halves the slippage exposure on harvest.
- Sweet spot: when a fresh bribe campaign pushes one DEX's APR > 60 %,
  rebalance 70/30 toward that side.

## Risks not modelled
- Active rebalancing cost: gas + slippage to migrate when APR gap > 15 %.
- slisBNB de-peg event hits both legs simultaneously (uncorrelated to
  which gauge you sit in).
- PCS MasterChefV2 pid may be deprecated when PCS migrates to v3 gauges;
  pid 175 is illustrative — verify via factory.

## TODO
- Resolve actual PCS v2 slisBNB/WBNB LP token via PCS_V2_FACTORY and
  the live `MasterChefV2.poolInfo(pid)` pool token.
- Replace hard-coded LOCAL_PCS_PID with subgraph lookup.
- Add active-rebalance harness: if THENA_APR / PCS_APR diverges > 1.5×,
  migrate principal across pools.
