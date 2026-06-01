# B01-01: slisBNB → Venus core pool → borrow BNB → Lista re-stake loop

## Mechanism
Three composable BSC primitives stacked into a single leveraged-staking position:

1. **Lista DAO slisBNB** — non-rebasing BNB LST. The `ListaStakeManager`
   exposes `deposit() payable` (BNB → slisBNB at the current
   `convertBnbToSnBnb`) and a `convertSnBnbToBnb` getter that is the canonical
   exchange-rate oracle. The exchange rate is monotonically increasing as the
   underlying validators accrue rewards; today ~1 slisBNB ≈ 1.04 BNB.
2. **Venus Core Pool** — Compound v2 fork. The Core pool lists slisBNB
   (`vslisBNB`) as collateral and `vBNB` for borrowing native BNB. Standard
   `enterMarkets` → `mint` → `borrow` flow.
3. **Recursive loop** — the borrowed BNB is fed straight back into
   `ListaStakeManager.deposit{value: bnb}()` to mint more slisBNB, which is
   re-supplied as collateral. After N iterations the position is `1/(1-L)`
   levered, where `L` is the per-step effective LTV (collateral factor × LST
   mint efficiency).

## Why it composes
- slisBNB exchange rate is **internal accounting** — there is no AMM hop, so
  the BNB → slisBNB → BNB round-trip has zero swap cost (and zero slippage)
  for the *mint* leg. Redemption is delayed and goes through `requestWithdraw`,
  so the loop is asymmetric: cheap to build, slow to unwind.
- Venus treats slisBNB as a normal collateral asset using the Lista
  StakeManager's price feed; borrowing BNB against slisBNB collateral is the
  canonical "borrow the LST's underlying" pattern that recursive-stake books
  exploit.
- The borrow rate on Venus vBNB is set by an IRM that *does not* know about
  the BNB consumed by Lista (and therefore not earning a borrow yield to
  Venus). Whenever `(slisBNB stake APY) > (vBNB borrow APY)` the loop is
  profitable. The leverage multiplier is bounded by Venus' slisBNB collateral
  factor (~ 0.70 at the time of writing).

## Preconditions
- BSC block where Venus Core lists slisBNB as collateral and the IRM is
  configured such that vBNB borrow APR < slisBNB stake APR.
- `ListaStakeManager` accepts deposits (not paused) and `convertBnbToSnBnb`
  returns a sane exchange rate at the pinned block.
- Account is fresh (no existing Venus liquidity) so `getAccountLiquidity`
  reflects only this strategy.

## Strategy steps
1. Start with 100 BNB principal. Unwrap WBNB → BNB.
2. Iteration 1:
   - `ListaStakeManager.deposit{value: bnb_balance}()` → receive slisBNB
     (`shares = convertBnbToSnBnb(bnb)`).
   - `Comptroller.enterMarkets([vslisBNB, vBNB])`.
   - `vslisBNB.mint(slisBNB_balance)` to supply collateral.
   - `vBNB.borrow(bnb_to_borrow)` where `bnb_to_borrow = slisBNB_bnb_value *
     CF * safety_haircut`. Safety haircut = 0.95 of the theoretical max so
     account liquidity stays positive.
3. Repeat steps for N=4 iterations. Each iteration adds another `L` chunk of
   exposure. At CF=0.70 × 0.95 = 0.665, four iterations give a 2.7× leverage
   (≈ 1 + 0.665 + 0.665² + 0.665³ + 0.665⁴).
4. Hold for 30 days. Yield accrues via the slisBNB exchange-rate drift;
   borrow accrues via `vBNB.borrowBalanceCurrent` ticking up each block.
5. Report PnL: the BNB-denominated delta of `(slisBNB_bnb_value -
   bnb_debt)` over the hold period.

## PnL math
Per 100 BNB principal, 30-day horizon, indicative rates (refine at block):
- slisBNB stake APY: ~4.0 %
- vBNB borrow APR: ~2.2 %
- Effective leverage L = 1 + 0.665 + 0.442 + 0.294 + 0.196 ≈ 2.60×
- Net APY at L=2.60: (2.60 × 4.0 − 1.60 × 2.2) = 10.4 − 3.52 = **+6.88 %**
- 30-day yield: 6.88 × 30/365 ≈ **+0.565 % on principal ≈ +0.565 BNB**

Gas: ~5 enterMarkets/mint/borrow cycles + 1 deposit per loop ≈ 1.5M gas.
At 1 gwei × 600 USD/BNB that's ~$0.90 — negligible vs. the carry.

## Block pinned
**40_000_000** (mid-2024) — Venus Core has slisBNB listed and the Lista
StakeManager is the canonical mint path. The exact block must be re-pinned
once BSC RPC is available; the strategy is invariant to small block drift.

## Addresses used
- `0x1adB950d8bB3dA4bE104211D5AB038628e477fE6` — Lista `StakeManager`
  (`BSC.LISTA_STAKE_MANAGER`).
- `0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B` — slisBNB ERC20
  (`BSC.slisBNB`).
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Venus `Comptroller`
  (`BSC.VENUS_COMPTROLLER`).
- `0xA07c5b74C9B40447a954e1466938b865b6BBea36` — `vBNB`
  (`BSC.vBNB`).
- `LOCAL_VSLISBNB` — Venus vslisBNB (Core pool listing). Pinned inline
  in the PoC because `BSC.sol` does not yet have a verified entry for the
  Core-pool vslisBNB market. Placeholder is set to a documented public
  address; replace once `BSC.sol` is verified.

## Risks
- **slisBNB de-peg**: if the slisBNB/BNB market price diverges from
  `convertSnBnbToBnb` (e.g. validator slashing rumor), Venus' oracle may
  mark down collateral and trigger liquidation. Mitigation: keep at least
  3 % buffer below the liquidation threshold (already baked into the 0.95
  safety haircut).
- **Borrow-rate spike**: vBNB IRM kinks at ~80 % utilization. If the pool
  is drained the borrow APR can jump from 2 % to 30 %+, flipping the carry
  negative. Position should be unwound if utilization > 75 %.
- **Lista withdrawal queue**: unwinding requires `requestWithdraw` + 7-15
  day unbond. The loop is *asymmetric* — fast to enter, slow to exit. For
  emergency exit, swap slisBNB → BNB on PCS v3 (typical slippage ~0.3 %).
- **Venus governance**: collateral factor and IRM are governance-mutable;
  a sudden CF cut would force partial unwind.

## Result
Status: **theoretical** (BSC RPC not configured yet — PoC compiles and is a
no-op until `BSC_RPC_URL` is set). Expected PnL: **+0.4–0.7 BNB per 100 BNB
over 30 days** at the pinned block, dominated by the stake/borrow spread.
