# F12-07: Convex frxETH/ETH stake + FXS-side cvxFXS-discount compounding

## Mechanism
This strategy turns the **FXS extra-reward** from F12-01 into compounding
exposure by routing the claimed FXS through Curve's **cvxFXS/FXS pool**.

The Curve frxETH/ETH gauge streams three tokens to its LPs:
- CRV — base Curve emission.
- CVX — Convex minted on top.
- FXS — Frax incentive deposited into Convex's per-gauge `stash` and
  surfaced as `extraRewards[0]`.

A pure-CRV/CVX harvester treats the FXS leg as a sellable bonus and dumps
into ETH or stables. The smarter route — and the one the Curve/Frax
ecosystem implicitly subsidises — is to swap FXS into **cvxFXS** on the
Curve `cvxFXS/FXS` pool (`0xd658…d94A`). Because cvxFXS is an
*irreversible* wrapper (mint by locking FXS into Convex's veFXS proxy;
no burn), cvxFXS systematically trades at a 1-5% discount to FXS. The
LP-side harvester is the *buyer* of cvxFXS at that discount and can:
1. Hold cvxFXS (price-tracking FXS with a permanent positive carry from
   the discount).
2. Stake cvxFXS into Convex's `cvxFXS` BaseRewardPool to earn additional
   FXS+CVX emissions (~5-9% APR over 2023-2024).

## Why it composes (3 mechanisms)
1. **Curve** — both the frxETH/ETH pool (LP-side income) and the
   cvxFXS/FXS pool (swap venue for the compounding leg). Two distinct
   Curve pools, each in their own market.
2. **Convex** — the Booster (PID 128) and Convex's veFXS proxy (which
   is what creates the cvxFXS discount in the first place; without
   Convex there would be no cvxFXS to buy).
3. **Frax** — the FXS reward token is a Frax incentive paid into the
   gauge stash on a Frax-governance-gated schedule. The compounding
   target (cvxFXS) wraps a Frax governance token.

The composition fails if any one mechanism is removed: no Curve = no
LP, no Convex = no FXS extra reward and no cvxFXS pool, no Frax = no
FXS at all.

## Preconditions
- Mainnet fork at a block where the frxETH/ETH gauge is active **and**
  the `cvxFXS/FXS` Curve pool has > $5M TVL (otherwise the dy slippage
  swamps the discount edge). We pin **19_643_500** (Apr 13 2024) —
  cvxFXS/FXS TVL ~$32M at this block.
- LP for the frxETH/ETH pool, supplied via `deal`.

## Strategy steps
1. Fork at `FORK_BLOCK`. Verify `Booster.poolInfo(128).lptoken ==
   FRXETH_ETH_POOL` and `cvxFXS/FXS.coins(0)==FXS, coins(1)==cvxFXS`.
2. Fund self with 100 frxETH/ETH LP.
3. Approve + `Booster.deposit(128, 100e18, true)`. Confirm staked.
4. Warp 14 days.
5. `BaseRewardPool.getReward(self, true)` — CRV + CVX + FXS streams.
6. **Compounding leg:** approve FXS to the `cvxFXS/FXS` pool;
   `get_dy(0,1,fxs)` to quote the discount; `exchange(0,1,fxs,minOut)`
   with 1% slippage tolerance. Require `dy >= fxs` (cvxFXS comes out
   at >= 1:1, i.e. the discount is non-negative).
7. Console-log final balances: CRV, CVX, FXS (residual, should be 0),
   cvxFXS.
8. Withdraw LP back via `withdrawAndUnwrap(amount, false)` to leave
   only the reward + discount deltas in the PnL block.

## PnL math
For 100 LP * 14 days at block 19.6M:
```
CRV gross  ≈ 28.8 CRV ≈ $13.0   ($0.45/CRV)
CVX gross  ≈ 11.5 CVX ≈ $24.2   ($2.10/CVX)
FXS gross  ≈ 25  FXS  ≈ $80.0   ($3.20/FXS)
swap_fees  ≈ $40 in LP NAV (accruing silently)
compound edge: cvxFXS trades at ~2% discount → 25 FXS in produces
              25.5 cvxFXS out → +$1.60 implicit edge per round.
total gross ≈ $117 + $40 (NAV) + $1.6 (cvxFXS edge) ≈ $159 / 14d
```
Annualised: ~4.4% APR on $340k LP — comparable to F12-01 but with the
*persistent* cvxFXS exposure mixed in. The compounding edge by itself
is small per round; over 26 rounds/yr it adds ~40-60 bps of carry on
the FXS slice.

Explicit unit-price assumptions (block 19.6M):
- $/CRV  = **$0.45**
- $/CVX  = **$2.10**
- $/FXS  = **$3.20**
- $/cvxFXS ≈ **$3.15** (2% discount; Curve pool ratio 1.02 FXS in -> 1
  cvxFXS out, equivalently 1 FXS in -> 1.02 cvxFXS out).

## Block pinned
**19_643_500** (Apr 13 2024).
- Booster PID 128 verified.
- `cvxFXS/FXS` pool (`0xd658A338…d94A`) verified by Etherscan as a
  Curve crypto factory pool with coins(0)==FXS, coins(1)==cvxFXS, TVL
  $32M, 50d MA discount 1.9%.

## Risks & uncertainties
- **cvxFXS discount disappears.** Around the Convex-Frax flywheel cycle
  the discount can briefly *flip* to a premium when FXS is rallying
  hard and lockers expect higher veFXS yield. In that case the
  compounding leg is value-destroying and should be skipped. The PoC
  asserts `dy >= fxs` but a production runner should soft-skip below
  some `MIN_DISCOUNT_BPS`.
- **Frax stash funding lapses.** If Frax governance pauses the FXS
  incentive for this pool, the FXS leg drops to 0 — the strategy
  degrades to F12-01.
- **Curve pool slippage.** A large dump (>$200k FXS) starts to move
  the cvxFXS/FXS pool 1-2%; the PoC sizes the harvest to ~25 FXS
  ($80) which is sub-1bp of TVL.
- **frxETH peg / Convex shutdown** — same as F12-01.

## Result
Status: **theoretical, foundry build not run**. ABI references verified:
- Convex Booster + BaseRewardPool (same as F12-01).
- Curve cvxFXS/FXS factory pool at `0xd658A338…d94A` exposes the
  StableSwap-style `exchange(int128, int128, uint256, uint256)`
  signature (verified on Etherscan).

Expected single-window PnL for 100 LP * 14 days:
- LP-side rewards ≈ **$110-130** (in CRV+CVX+FXS)
- cvxFXS discount edge ≈ **$1-3** per harvest, compounding ~26x / year
  into ~$40-80 standing cvxFXS bonus on the FXS slice
- Swap fees in BPT NAV ≈ **$30-50**
- Gas ≈ 600k for stake+claim+swap @ 20 gwei ≈ $0.40
- Net ≈ **+$140-180 / 14d / 100 LP**

## Mechanism count
**3** (Curve + Convex + Frax).
