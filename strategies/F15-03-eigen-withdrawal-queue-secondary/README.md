# F15-03: EigenLayer 7-day withdrawal-queue exit + secondary market

## Mechanism

EigenLayer's `DelegationManager` enforces a **7-day withdrawal delay**
(originally 7 epochs, currently 14 days post-2024-Q3 governance, but 7d at the
block we pin). The full withdrawal flow:

1. Staker calls `queueWithdrawals(QueuedWithdrawalParams[])` — burns
   `shares` on the strategy, emits a `WithdrawalQueued` event with a
   `withdrawalRoot`.
2. Wait ≥ `MIN_WITHDRAWAL_DELAY_BLOCKS` (50,400 blocks @ 12s/block ≈ 7 days
   in 2024).
3. Staker calls `completeQueuedWithdrawal(withdrawal, tokens, idx, true)`
   — receives the underlying LST back.

During the 7-day window the staker holds a **non-transferable claim** —
unlike Lido's `unstETH` NFT or Rocket Pool's ETH-deposit-tokens, EL's
withdrawal credential is **not represented as an ERC721/ERC1155** at the
block we pin. There is no canonical secondary market.

This strategy explores the **theoretical** profit if a secondary market existed
(some EIP / EigenLayer governance proposals have floated this):

- A withdrawer who needs immediate liquidity might sell their claim at
  ~98-99% of face for a 7-day wait. Annualised, that's a 50-100% discount
  rate, which dwarfs every other DeFi rate.
- A buyer with patience captures the spread risk-free (modulo slashing,
  which is rare and bounded).

## Why it composes

The "compose" here is a meta-composition: it's the **same primitive** as
Lido's `unstETH` NFT (transferable claim on a queued withdrawal). Lido's NFTs
trade on OpenSea/Blur at ~99-99.5% of face for 1-7 day waits.

If EigenLayer added withdrawal NFTs, the secondary-market mechanics would
inherit Lido's pricing curve. The block-pinned PoC shows the on-chain queue
ops; the secondary-market leg is documented as a TODO awaiting protocol
upgrade.

## Preconditions

- Block: 19,700,000 (mid-Apr 2024). Need to first have stETH-strategy
  shares to withdraw. The PoC's setup step does a `depositIntoStrategy`
  first to mint shares (if cap is open) OR uses an existing depositor's
  shares via prank.
- The staker must be **delegated** to themselves (i.e. not delegated to
  any operator) OR have undelegated. `queueWithdrawals` does not require
  un-delegation in the 2024-Q2 contracts.

## Strategy steps

1. Acquire EL stETH-strategy shares (deposit at this block).
2. `IEigenDelegationManager.queueWithdrawals([{strategies:[STETH_STRATEGY],
   shares:[half_of_balance], withdrawer:address(this)}])` — start the clock.
3. **Theoretical leg:** if a transferable NFT existed, list it on a fictional
   secondary at 99% of face. This is logged, not executed.
4. Roll the fork forward 50,500 blocks (~7 days) past the delay.
5. `completeQueuedWithdrawal(withdrawal, [stETH], 0, true)` — claim the
   stETH back.
6. End PnL — net should be ~0 cash (modulo gas) at the test block.

## PnL math

```
Scenario A: hold to maturity (the only currently-implementable path)
  Equity in:     50 stETH-equiv shares
  Wait:          7 days
  Equity out:    50 stETH (plus tiny stETH rebase yield over 7 days)
  Cash PnL:      +50 × (3.0%/52) ≈ +0.029 stETH ≈ $87
  Lost EL points: 50 shares × 7 days × $0.20/share-day ≈ $70
  Net:           ~+$17 (or roughly break-even)

Scenario B: theoretical secondary-market sale at 99% of face
  Seller's PnL:
    receive 49.5 stETH immediately, give up 50 stETH claim
    -0.5 stETH (~$1,500) cost vs hold-to-maturity
    + the option value of immediate liquidity
  Buyer's PnL:
    pay 49.5 stETH, wait 7d, receive 50 stETH + stETH yield
    +0.5 stETH + 0.029 ≈ +0.53 stETH (~$1,590) gross / 7d
    = ~52% annualised, risk-free if you trust EL slashing model.
  Both sides happy; this is the missing primitive.

Scenario C: buyer-side, repeat the cycle
  $50,000 capital, weekly turnover at 1% gross:
    52 cycles × 1% = ~67% APR (compounded), or ~52% simple
```

## Block pinned

- Fork block: 19,700,000.
- Time-roll: `vm.roll(block.number + 50_500)` + `vm.warp(block.timestamp + 7 days + 12*500)`.

## Risks

- **No secondary market exists at this block.** The full leg of profit is
  TODO. Logging the queue-start and queue-complete makes the *mechanics*
  reproducible.
- **EigenLayer slashing.** A withdrawal queued during a slashing event may
  be slashed before completion. Probability is low historically (no slashing
  events in 2023-2024), but non-zero.
- **Withdrawal delay extension.** Governance can extend the delay; queued
  withdrawals at the old delay may be subject to the new delay (the v2024
  contracts pin delay at queue time per the spec, but check at fork).
- **Operator selection.** If the staker was delegated, undelegation triggers
  forced withdrawal queueing under different params; the PoC sticks to
  self-delegated.

## Result

Status: **theoretical / mechanics-only.** The on-chain queue/complete cycle
runs end-to-end at fork; the **secondary-market leg requires a primitive
that does not exist at this block** and is documented as a known gap.

PnL (hold to maturity): roughly break-even; loses ~$70 in EL points + gas,
gains ~$87 in stETH rebase yield over 7d.

PnL (with a hypothetical 99%-of-face secondary): ~$1.5k/cycle gross for
the buyer; the seller pays for option value.
