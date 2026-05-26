# F15-05: EigenLayer operator-delegation alpha (multi-AVS layering)

## Mechanism

EigenLayer's restaking model splits "deposit" from "delegation":

1. `StrategyManager.depositIntoStrategy(strategy, token, amount)` mints
   strategy-shares to the staker but leaves them **un-delegated** (no operator
   is earning rewards on them, no AVS slashing condition is wired up).
2. `DelegationManager.delegateTo(operator, sig, salt)` then assigns ALL of
   that staker's strategy-shares to a single registered EigenLayer operator.
   The operator's `operatorShares(operator, strategy)` view increases by
   exactly the staker's share balance.

The operator is the unit that **opts in to specific AVSs**. AVSs (EigenDA,
AltLayer MACH, Witness Chain, Hyperlane ISM, eOracle, Lagrange ZK Coprocessor,
etc.) each emit rewards in their own token or in EIGEN, and they slash on
their own conditions. An operator opted in to N AVSs earns the **sum** of all
their reward streams on the same restaked notional.

The alpha: **delegating to a multi-AVS operator captures N reward streams on
1 unit of stETH risk**, while delegating to a single-AVS operator captures
only 1 stream. The slashing risk is the **union** of the AVS slashing
conditions, but historically (2024) no AVS has slashed.

This strategy delegates to P2P.org (`0xDbEd88D83176316fc46797B43aDeE927Dc2ff2F5`),
which at the pinned block was opted in to **EigenDA + AltLayer MACH + ARPA
Network**, capturing 3 reward streams on a single restake.

## Why it composes (3-mechanism)

Three independent mechanisms stack:

1. **LST layer (Lido)** — stETH continues to earn ~3.0% staking yield while
   deposited. EL never touches the underlying validators; stETH just sits
   in the strategy as the share-rate denominator.
2. **EigenLayer points + EIGEN AVS rewards** — accrue automatically on any
   delegated stETH-strategy share at the protocol-wide rate.
3. **Multi-AVS operator rewards** — operator forwards a pro-rata cut of each
   AVS's reward emission to its delegators. With 3 AVSs, that's 3 token
   streams (EIGEN-from-EigenDA, ALT or USDC from MACH, ARPA from Arpa).

These are **all simultaneous on the same notional**. None of the three
mechanisms displaces the others.

## Preconditions

- Block: 20,300,000 (late Jul 2024). EL stETH cap was open in this window;
  P2P.org operator was registered and actively earning multi-AVS rewards;
  AVS reward distribution (EigenLayer Rewards v0) live.
- stETH whale for funding (rebasing → no `deal()`).
- P2P operator must return `isOperator(P2P_OPERATOR) == true` at FORK_BLOCK.
  If not, the PoC degrades to deposit-only.

## Strategy steps

1. Fund 50 stETH from a whale.
2. Snapshot PnL.
3. `depositIntoStrategy(STETH_STRATEGY, stETH, 50e18)` — mint shares.
4. Read `dm.isOperator(P2P_OPERATOR)`; read `dm.operatorShares(P2P_OPERATOR,
   STETH_STRATEGY)`; read `strat.totalShares()`. These provide:
   - "operator AVS density" = operatorShares / totalShares (how concentrated
     this operator is on stETH — high density = more AVS reward routing).
5. `delegateTo(P2P_OPERATOR, emptySig, 0)` — empty signature works when the
   operator has set `delegationApprover = address(0)` (the default for
   most operators including P2P).
6. Verify `dm.delegatedTo(address(this)) == P2P_OPERATOR`.
7. Re-read `operatorShares(P2P_OPERATOR, STETH_STRATEGY)` — should equal
   the previous value + our minted shares.
8. End PnL — fork-block PnL is ~$0 (no rewards have accrued yet); the alpha
   is the 1-year forward accrual documented below.

## PnL math

```
50 stETH equity (~$150k @ $3k ETH).
1-year hold, P2P operator delegated.

Lido yield (LST layer)
  50 × 3.0% = 1.50 stETH ≈ $4,500

EigenLayer native points & rewards
  50 × 1 pt/ETH/day × 365 = 18,250 pts
    @ $3.50/pt (EIGEN listing assumption) ≈ $63,875
  EIGEN AVS-routed base reward: 50 × 0.4% (2024 rate)
    = 0.20 stETH ≈ $600

Multi-AVS operator-layered rewards (the strategy's incremental alpha)
  EigenDA            50 × 0.20% = 0.10 stETH  ≈   $300
  AltLayer MACH      50 × 0.35% = 0.175 stETH ≈   $525
  ARPA Network       50 × 0.15% = 0.075 stETH ≈   $225
                                  -----------    ------
                                  0.35 stETH    $1,050
  PLUS each AVS's airdrop optionality (ALT token did launch in Jan 2024;
  EigenDA & ARPA are TGE-pending). Mid-case estimate:
    + $2,000-4,000 of airdrop value over the year.

Total (1y, 50 stETH equity ≈ $150k):
  Base case:         $4,500 + $63,875 + $600 + $1,050 + $3,000 ≈ $73,000
  vs single-AVS operator (e.g. EigenDA-only): ~$70,200 — alpha ~$2,800/yr
  vs no delegation (just deposit + leave un-delegated): ~$68,975 — alpha ~$4,000/yr

The delegation alpha is small in dollar terms but FREE — it's the same
deposit, just routed to a higher-throughput operator. Annualised this is
~2-3% of cash return uplift on the EIGEN-points-equivalent value.
```

## Block pinned

- Fork block: 20,300,000.
- Operator: `0xDbEd88D83176316fc46797B43aDeE927Dc2ff2F5` (P2P.org).

## Risks

- **Operator slashing risk is the OR of every opted-in AVS.** If any one
  of EigenDA / MACH / ARPA / etc. slashes the operator, ALL delegated stake
  is exposed. The Markowitz argument is that AVS slashing conditions are
  largely uncorrelated (data-availability mis-attestation, ZK proof
  withholding, oracle deviation are distinct fault modes), but a software
  bug in the operator's stack could trigger several simultaneously.
- **Operator metadata can change.** Operators opt in / out of AVSs without
  notifying delegators. The expected reward stream at delegation-time can
  shrink mid-hold.
- **`delegationApprover` gate.** If the chosen operator has set
  `delegationApprover != address(0)`, an empty-sig `delegateTo` reverts. The
  PoC wraps in try/catch and logs; production must fetch a signed approval
  from the operator first.
- **Reward distribution lag.** EigenLayer Rewards v0 paid via Merkle drops
  on irregular cadence (initially monthly). PnL accrual is bursty, not
  continuous.
- **Undelegation cost.** Un-delegating triggers a forced queued-withdrawal
  of every delegated share with the 7-day delay. Switching operators is
  therefore expensive once you've committed.

## Result

Status: **mechanically reproducible end-to-end at fork block.** The deposit
and `delegateTo` calls execute; the `operatorShares()` view reads confirm
the share movement. Forward 1y dollar PnL depends on EIGEN price + AVS-token
airdrop assumptions documented above.

PnL (1y, 50 stETH equity ≈ $150k):
- Base (one AVS airdrops realise): ~+$73k.
- Bull (all 3 AVS airdrops realise meaningfully): ~+$85-100k.
- Bear (zero AVS rewards): ~+$4.5k cash yield only (Lido).
- Alpha vs no-delegation: ~+$4k/yr free.
