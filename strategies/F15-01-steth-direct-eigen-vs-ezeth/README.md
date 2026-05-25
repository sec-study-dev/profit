# F15-01: stETH direct EigenLayer deposit vs Renzo ezETH alternative

## Mechanism

EigenLayer's `StrategyManager.depositIntoStrategy(strategy, token, amount)`
accepts a list of LST-specific "strategy" proxies. Each one is an ERC20-share
wrapper over the underlying LST: shares are minted at the prevailing
`sharesToUnderlying` rate, and AVS reward distribution + EigenLayer points are
keyed off `(strategy, staker)` over time.

The competing path is an LRT — for stETH this is most naturally **Renzo's
ezETH** (which restakes stETH/wBETH/ETH on EigenLayer on the user's behalf).
ezETH is a non-rebasing wrapper that bakes in:

- Lido staking yield (3.0%)
- EigenLayer points (Renzo claims them on the user's behalf; redistributes
  via airdrop / RZR token)
- AVS rewards (Renzo aggregates and re-distributes)
- **minus an LRT fee** — Renzo's documented 10% performance fee on AVS rewards
  + an implicit "operator selection" fee built into the share rate.

This strategy is the **A/B comparison**: at a chosen block during a cap-open
window, deposit `X` stETH directly into the EigenLayer stETH strategy proxy
`0x93c4b944D05dfe6df7645A86cd2206016c51564D`, vs mint ezETH for the same `X`
of stETH (or ETH-equivalent). The native path saves the LRT performance fee
and lets the depositor pick the operator (and thus the AVS exposure).

## Why it composes

Direct EigenLayer = (raw stETH yield) + (raw EigenLayer points) + (AVS rewards
from one specific operator).
LRT (ezETH) = (raw stETH yield) + (LRT-aggregated EL points, **discounted
by fee**) + (basket of AVS rewards, **also fee-haircut**) + (RZR / ezETH
airdrop premium — sometimes positive).

The decisive variables are:

1. EL-points $/point at unlock — known once EIGEN listed (~$3.50 in May 2024).
2. ezETH airdrop premium vs the underlying LST notional — was ~+8-15% at peak,
   ~0 by Jul 2024 (ezETH depeg).
3. Renzo's fee burn — ~10% on AVS rewards.

When (3) > (2), **native restake out-performs ezETH on a points-adjusted
$/notional basis.** The "cap window" matters because direct deposits are
rate-limited per LST.

## Preconditions

- Block: 19,650,000 (early Apr 2024 — wstETH/stETH caps re-opened on EL).
- EigenLayer stETH-strategy address verified at this block:
  `0x93c4b944D05dfe6df7645A86cd2206016c51564D` (this is the long-running stETH
  strategy proxy; cross-reference: EigenLayer docs + DefiLlama Restake page).
- Renzo `RestakeManager` accepts stETH directly via `deposit(stETH, amount)`
  at this block: address `0x74a09653A083691711cF8215a6ab074BB4e99ef5`.
- `EIGEN_STRATEGY_MANAGER` whitelisted the stETH strategy for deposit at this
  block (`strategyIsWhitelistedForDeposit` returns true).

## Strategy steps

1. Fund test contract with 100 stETH (via Lido whale prank — stETH rebases
   and is not `deal`-friendly).
2. Snapshot PnL with `_startPnL`.
3. **Leg A (native):** approve 50 stETH to `EIGEN_STRATEGY_MANAGER`, call
   `depositIntoStrategy(STETH_STRATEGY, stETH, 50e18)`; record shares minted.
4. **Leg B (LRT):** approve 50 stETH to `RENZO_RESTAKE_MANAGER`, call
   `deposit(stETH, 50e18)`; record ezETH minted.
5. End PnL — tracked tokens are stETH (decreases), ezETH (increases). The
   EigenLayer-strategy shares are NOT a tracked ERC20 from the contract's
   POV (the SM holds them as bookkeeping); we record the implied notional
   via `stakerStrategyShares(address(this), STETH_STRATEGY)`.

## PnL math

This PoC is an **accounting comparison**, not an arb. The dollar PnL at the
test block is essentially $0 — both legs convert stETH 1:1 into a deposit
receipt of equal underlying value. Where the strategies diverge is in the
**accrual rate** over the holding period (1 year):

```
On 50 stETH (100 ETH equity total, 50 native + 50 ezETH), 1y:

Native (50 stETH in EL stETH-strategy):
  Lido yield     50 × 3.0%       = 1.50 ETH
  EL points      50 × 1pt/ETH/day × 365 = 18,250 pts
    @ $3.50 EIGEN/pt-equiv (May 2024 listing) ≈ $63,875
  AVS rewards (single operator, e.g. EigenDA)
    ~0.5%/yr early                        = 0.25 ETH
  Subtotal: 1.75 ETH + $63,875 ≈ $69,125

ezETH (50 stETH-equivalent worth of ezETH):
  Lido yield     same             = 1.50 ETH
  EL points (Renzo-claimed, -10% fee)    ≈ $57,500
  AVS rewards basket (-10% fee)          = 0.225 ETH
  RZR airdrop premium (Apr 2024 still positive ~+10%)
    50 × 10%                             = ~$15,000 one-off
  Subtotal: 1.725 ETH + $72,500 ≈ $77,675

Delta (LRT - native, 1y) at this block: ~+$8,500 in LRT's favour
```

Interpretation: at block 19,650,000, the **ezETH path was still ahead** because
the RZR airdrop expectation outweighed the 10% fee. By blocks 20,200,000+
(late July 2024) after the ezETH depeg, the RZR premium had collapsed to ~0,
and the calc flips: native wins by ~$6-7k on 50 stETH/yr.

## Block pinned

- Fork block: 19,650,000 (Apr 2024 cap-open window).
- Alternative block to test the **flipped** regime: 20,300,000 (Aug 2024).

## Risks

- **Operator selection risk (native only).** If you pick a low-AVS operator,
  AVS rewards underperform; the LRT diversifies across operators.
- **Cap closure.** Between `19,500,000` and `19,800,000` the stETH cap on EL
  oscillated open/closed. `depositIntoStrategy` reverts if the strategy is
  paused — the PoC wraps in try/catch and emits a clear log if so.
- **EIGEN price assumption.** $3.50/pt is the May 2024 listing peak; airdrop
  recipients realised less (vesting, sybil clawbacks).
- **ezETH depeg.** The Apr 2024 RZR airdrop announcement triggered a -10%
  ezETH depeg within hours of cap-open; the airdrop premium evaporated.

## Result

Status: **empirical at fork-time, theoretical for 1y forward accrual.** The
deposit transactions execute at the pinned block; the dollar comparison
between native and LRT depends on forward-looking token-price assumptions
that are documented but not enforceable on-chain.

PnL at exit (1y, 100 stETH equity split 50/50):
- At block 19,650,000 (pre-depeg): LRT ahead by ~$8-10k.
- At block 20,300,000 (post-depeg): Native ahead by ~$5-8k.
