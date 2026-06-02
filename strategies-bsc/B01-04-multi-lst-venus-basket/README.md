# B01-04: 50/50 slisBNB + BNBx basket on Venus → borrow BNB → split re-stake

## Mechanism
Single-loop, multi-collateral variant of B01-01/B01-02. Instead of choosing
one LST and concentrating the loop, this strategy diversifies the collateral
across **two independent BNB LSTs** simultaneously while sharing one BNB
debt leg. The composition exploits three primitives:

1. **Lista DAO slisBNB + Stader BNBx** — two non-rebasing BNB LSTs with
   independent validator sets, independent exchange-rate oracles, and
   different stake-APY profiles. Holding both reduces the slashing /
   reward-bug variance of either.
2. **Venus Core pool, multi-asset collateral** — Compound v2's
   `getAccountLiquidity` aggregates *all* `enterMarkets`-ed assets, so both
   slisBNB and BNBx can be supplied as collateral simultaneously and share
   the same borrow account. The borrow capacity is the CF-weighted sum.
3. **Single vBNB borrow leg, split re-stake** — borrowed BNB is split
   50/50 between Lista StakeManager and Stader StakeManager each iteration,
   keeping the basket weighting stable as the loop deepens.

## Why it composes
- Different LSTs' exchange-rate drifts are *correlated but not identical*
  (different validator sets, different MEV exposure, occasional protocol
  bugs). A 50/50 basket has a strictly lower variance than either single
  leg, with a small drag on expected return (the lower-yield leg pulls down
  the mean).
- Venus aggregates collateral additively under `enterMarkets`. The
  effective LTV is `(0.70 × slisBNB_value + 0.65 × BNBx_value) / total`.
  For a balanced basket: `(0.70 + 0.65) / 2 = 0.675`. Comparable to the
  slisBNB-only loop's 0.665 effective LTV after safety haircut — the basket
  costs ~zero leverage to diversify.
- Splitting re-stake 50/50 each iteration prevents the basket from drifting
  to one LST as the loop runs (which would defeat the diversification).

## Preconditions
- BSC block where Venus Core lists **both** slisBNB (`vslisBNB`) and BNBx
  (`vBNBx`) as collateral simultaneously, with vBNB as the borrow asset.
  This is the strict precondition; if only one is listed at the pinned
  block, fall back to the single-leg version (B01-01 / B01-02).
- Both Stader and Lista StakeManagers operational.

## Strategy steps
1. Start with 100 BNB principal in native form.
2. Split: 50 BNB → Lista StakeManager → slisBNB; 50 BNB → Stader
   StakeManager → BNBx.
3. `Comptroller.enterMarkets([vslisBNB, vBNBx, vBNB])`.
4. `vslisBNB.mint(slisBNB_balance)` and `vBNBx.mint(BNBx_balance)`.
5. Iteration loop (N=4):
   - `getAccountLiquidity` → `liq`.
   - `vBNB.borrow(liq * SAFETY_BPS / 10_000)`.
   - Split the borrowed BNB 50/50 between `ListaStakeManager.deposit{value}()`
     and `StaderStakeManager.deposit{value}()`.
   - `vslisBNB.mint` and `vBNBx.mint` the freshly minted shares.
6. Hold 30 days; re-mark both LST prices using their on-chain exchange
   rates; report PnL.

## PnL math
Per 100 BNB principal, 30-day horizon:
- slisBNB stake APY: 4.0 %; BNBx stake APY: 3.8 %. Basket APY: 3.9 %.
- vBNB borrow APR: 2.2 % (Venus Core).
- Effective LTV: 0.675 × 0.95 safety = 0.641.
- Effective leverage L = 1 + 0.641 + 0.411 + 0.263 + 0.169 ≈ 2.48×
- Net APY at L=2.48: (2.48 × 3.9 − 1.48 × 2.2) = 9.672 − 3.256 = **+6.42 %**
- 30-day yield: 6.42 × 30/365 ≈ **+0.527 % on principal ≈ +0.527 BNB**

The 0.46 ppt APY hit vs. single-leg slisBNB (+6.88 % B01-01) is the
"insurance premium" paid for halving validator-set concentration risk.

## Block pinned
**40_000_000** (mid-2024) — same window as B01-01. Both LST collateral
listings must be live; refine once vslisBNB and vBNBx are verified.

## Addresses used
- `BSC.LISTA_STAKE_MANAGER` (`0x1adB...7fE6`)
- `BSC.slisBNB` (`0xB0b8...4A1B`)
- `BSC.BNBx` (`0x1bdd...6aE4`)
- `LOCAL_STADER_STAKE_MANAGER` (`0x7276...0F2F`) — inline; verify.
- `LOCAL_VSLISBNB` (`0xd3CC...894A`) — inline; verify.
- `LOCAL_VBNBX` (`0x5c12...d18F`) — inline; verify.
- `BSC.vBNB` (`0xA07c...ea36`)
- `BSC.VENUS_COMPTROLLER` (`0xfD36...8384`)

## Risks
- **Listing precondition fail**: if either vslisBNB or vBNBx is not yet
  listed in Core at the pinned block, `enterMarkets` returns a non-zero
  error code. The PoC reverts; strategy must fall back to single-leg.
- **Cross-LST correlation in stress**: validator slashing on either LST
  during the hold drops the basket's value disproportionately because both
  serve the BSC validator set. True orthogonality requires combining BNB
  LSTs with BTC-LSDs (see B12 / B11 families).
- **Loop arithmetic skew**: if Lista and Stader return materially different
  `convertBnbToSnBnb` / `getExchangeRate`, the 50/50 split by BNB amount
  produces a non-50/50 split by collateral value. The PoC accepts this
  drift (≤ 1 % at any sane block) for code simplicity.
- All risks inherited from B01-01 (de-peg, governance, withdrawal queue).

## Result
Status: **theoretical** (BSC RPC not configured). Expected PnL: **+0.4–0.6
BNB per 100 BNB over 30 days**. Risk profile is meaningfully tighter than
single-leg loops — useful for size-constrained books where validator
concentration is a binding constraint.
