# F13-08: Balancer wstETH/WETH BPT → Aura staking — triple-yield carry

## Mechanism

A **2-protocol** composition that stacks Aura Finance staking on top
of F13-03's Balancer ComposableStable LP position. The same BPT that
F13-03 holds in an EOA is here deposited into the Aura Booster
(`0xA57b8d98dAE62B26Ec3bcC4a365338157060B234`) under the gauge's PID,
which:

1. **Forwards the BPT to Balancer's gauge** for the
   wstETH/WETH CSP. The gauge earns BAL emissions proportional to
   veBAL gauge-weight votes.
2. **Boosts those BAL emissions via Aura's vlAURA position** —
   Aura concentrates veBAL voting power and pays through a
   ~70-90% boost to depositors that route via the Booster instead
   of staking the gauge directly.
3. **Mints AURA tokens** as a parallel reward stream alongside the
   boosted BAL emissions.

Stack of yield streams:

| Source                          | Magnitude (late 2024) | Captured by F13-03? | By F13-08? |
|---------------------------------|------------------------|---------------------|------------|
| Pool swap fees (in BPT NAV)     | ~30-60 bps APR        | Yes                 | Yes        |
| wstETH staking yield (rate prov)| ~175 bps APR (50% wt) | Yes                 | Yes        |
| BAL gauge emissions (boosted)   | ~200-400 bps APR      | No                  | **Yes**    |
| AURA token emissions            | ~80-150 bps APR       | No                  | **Yes**    |

Aura's emission schedule decays over time; numbers above are the
rough late-2024 range for the wstETH/WETH gauge.

## Why it composes

- The position is **still composable downstream**: Aura's stake
  receipt is an ERC20 that some money markets recognise as
  collateral; further leverage on top would be a 3-mech extension
  (F13-08 stops at stake/unstake to keep the PoC focused).
- This is the **Aura-Booster analog of F13-03**, demonstrating
  the canonical "BPT → Aura → BAL/AURA carry" pipeline used by
  every yield aggregator (Yearn, Beefy, Convex-Aura) in the
  Balancer ecosystem.
- Mechanism count: **2** (Balancer LP + Aura staking).

## Preconditions

- 50 WETH funded on the test contract.
- The Aura PID (`153` at late-2024) maps to the wstETH/WETH BPT
  gauge. If a gauge re-vote moves the PID, update the constant.
- The Aura pool must not be `shutdown` (gauges can be marked
  shutdown if Balancer removes them from the gauge controller).

## Strategy steps

1. Fund 50 WETH.
2. Resolve pool token order (BPT slot, WETH slot) via
   `IBalancerVault.getPoolTokens(poolId)` — same approach as F13-03.
3. `Vault.joinPool(...)` with `EXACT_TOKENS_IN_FOR_BPT_OUT`,
   single-sided WETH-in.
4. Read BPT balance.
5. `IAuraBooster.deposit(PID, bptAmount, true)` — `true` flag
   auto-stakes into the rewards contract; the BPT is custodied by
   Aura.
6. Read the rewards contract address from `Booster.poolInfo(pid)` →
   `crvRewards`. Snapshot `IAuraRewards.balanceOf(this)`; must equal
   the BPT amount deposited.
7. `vm.roll(block.number + 1)`, `vm.warp(+12)` to advance one block
   (the PoC's purpose is mechanics, not multi-day emission accrual).
8. `IAuraRewards.withdrawAndUnwrap(bpt, true)` to pull BPT back +
   claim BAL/AURA rewards.
9. `Vault.exitPool(...)` to redeem BPT for single-asset WETH.
10. Report PnL (BAL + AURA balances are tracked; PoC value is ~0
    for 1 block of emissions).

## PnL math (annualised carry)

At 50 WETH notional (~$160k @ ETH=$3,200):

- Pool swap fee + wstETH rate ≈ 2.05% APR ≈ **+$3,280/year** (same
  as F13-03).
- Aura-boosted BAL ≈ 3% APR ≈ **+$4,800/year**.
- AURA emissions ≈ 1.2% APR ≈ **+$1,920/year**.

**Total gross APR ≈ 6.25%** ≈ **+$10,000/year on $160k**.

After:
- Balancer protocol fee on swap fees (already netted in pool's NAV).
- Aura platform fee (4% of BAL/AURA): ≈ -$270/year.
- Gas for periodic claim + restake (manual rebalance every 1-4
  weeks, ~150k gas × 12 events ≈ 1.8M gas/year ≈ $25 at 5 gwei).

**Net APR ≈ 6.0%** ≈ **+$9,700/year on $160k**.

For the 1-block PoC the realised yield is ~$0; the PoC validates
the **position mechanics** (BPT round-trip, Aura accepting the
deposit, withdraw returning BPT + claim outputs).

## Block pinned

- `FORK_BLOCK = 20_900_000` (Oct 2024 era). Aura mainnet active,
  the BPT gauge has been listed since mid-2023.

## Risks

- **Aura PID drift**: if Balancer adds new gauges or shuts the
  current one, the PID changes. The PoC reads `poolInfo(pid)` and
  asserts `lptoken == BPT`; if this fails, re-verify the PID.
- **Smart-contract risk**: Aura's Booster has been audited but
  composability bugs (e.g. reentrant claim during emergency
  withdrawal) have historically affected Convex-fork systems.
- **Gauge weight collapse**: if veBAL voters move emissions away
  from wstETH/WETH, the BAL APR drops. Wave 4 deployment should
  monitor `GaugeController.gauge_relative_weight(gauge)`.
- **AURA price risk**: AURA reward value depends on AURA's market
  price; emissions valuation can drop sharply.
- **Lockup**: Aura's Booster has no withdraw lock for the main
  stake path (`withdrawAndUnwrap` is instant), but veBAL boost
  computation has a 16-week vlAURA lock for the boost provider
  (out of scope for this PoC's depositor side).

## Result

- Status: **mechanically demonstrated**. The PoC successfully
  joins Balancer, stakes BPT into Aura, withdraws + claims, and
  exits Balancer back to WETH.
- Annualised carry: **+6.0% net APR** at 50 WETH notional,
  late-2024 conditions.
