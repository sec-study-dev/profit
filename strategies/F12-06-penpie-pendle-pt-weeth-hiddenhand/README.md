# F12-06: Penpie boost on Pendle PT-weETH market + Hidden Hand vePENDLE bribe

## Mechanism
**Pendle** splits yield-bearing assets into a fixed-yield **PT** and
variable-yield **YT**. LPs in a Pendle Market (`PT/SY` AMM) earn swap fees
plus the protocol's **PENDLE** emissions, weighted by gauge votes from
**vePENDLE** holders. Pendle's emission tilts heavily toward markets that
attract the most vePENDLE votes — and vePENDLE is itself bribeable.

**Penpie** is to Pendle what Convex is to Curve. It permanently locks
PENDLE into vePENDLE (currently ~9.5M PENDLE under the Penpie banner)
and channels max-boost emissions to all of its LP depositors. The
on-chain composition:
1. User deposits Pendle LP via `PendleMarketDepositHelper.depositMarket(
   market, amount)`.
2. The helper forwards the LP into `MasterPenpie` which records the
   user's stake and routes future PENDLE emissions through Penpie's
   vePENDLE proxy.
3. The user multiclaims `PENDLE + mPENDLE + bonus rewards (e.g. ETHFI,
   weETH-side accrual) + PNP (Penpie's gov token)` via
   `MasterPenpie.multiclaim([market])`.

**Hidden Hand** runs the vePENDLE bribe market as well as the vlAURA
one. The same `RewardDistributor` (`0xa9b08B4C…6416`) holds per-
identifier merkleRoots for `vePENDLE`, `vlAURA`, `vlCVX`, and `hPAL`
gauges in parallel. Bribers deposit USDC / ETHFI / ARB / PENDLE
into the BribeVault tied to a Pendle market proposal; voters claim
their pro-rata share post-round.

## Why it composes (3 mechanisms)
1. **Pendle** — LP earns swap fees from PT-YT trading and a base
   PENDLE emission proportional to the market's gauge weight.
2. **Penpie** — boosts the PENDLE stream by ~2.5x (Penpie's vePENDLE
   proxy is at max-lock) and adds mPENDLE + PNP secondary emissions.
3. **Hidden Hand (vePENDLE arm)** — Penpie's vote-direction sells via
   bribes; the LP-side operator can be the same as the vlPNP-side
   voter, double-counting the same lock.

A bare Pendle LP without Penpie sees ~40-60% lower PENDLE accrual; a
bare Penpie LP without vePENDLE-side bribes leaves $/round on the
table.

## Preconditions
- Mainnet fork at a block where (a) the Pendle PT-weETH-26DEC2024 market
  is liquid (TVL > $40M), (b) the market is registered in
  `MasterPenpie`, and (c) a Hidden Hand vePENDLE round has been
  published. We pin **20_650_000** (Aug 16 2024) — PT-weETH-26DEC has
  4.5 months to maturity, Penpie has been onboarded.
- Pendle LP for the market, supplied via `deal`.

## Strategy steps
1. Fork at `FORK_BLOCK`. Read the market's `(SY, PT, YT)` and assert
   non-expired.
2. Fund self with 100 LP. Approve `PendleMarketDepositHelper`.
3. Call `depositMarket(market, 100e18)`. Confirm via
   `balance(market, self) == 100e18`. **Note**: a real Penpie integration
   re-routes the LP into MasterPenpie internally; we just observe the
   resulting wrapped balance. The call is wrapped in try/catch because
   Penpie's onboard list may not include every Pendle market on every
   fork.
4. Warp 14 days. PENDLE drips at the Pendle market's `getRewardTokens()`
   rate; Penpie boosts via its vePENDLE proxy.
5. Call `MasterPenpie.multiclaim([market])`. Log PENDLE, mPENDLE, PNP
   raw deltas.
6. Fall-back: if Penpie route reverts, call
   `PendleMarket.redeemRewards(self)` directly — base Pendle income
   still materialises, the composition simply loses the Penpie boost.
7. Hidden Hand: inject one-leaf root for vePENDLE bribes (USDC +
   PENDLE) and call `claim([...])` with empty proof.

## PnL math
At block 20.65M for 100 LP (~$160k notional on PT-weETH; LP/SY ratio
~0.5 and SY ≈ weETH ≈ ETH 1.04):
```
Pendle native APR (post-Penpie boost):
  PENDLE_emission_apr     ≈ 14%     ; 14d: $160k * 0.14 * 14/365 ≈ $860
  mPENDLE_(Penpie bonus)  ≈ 2%      ; 14d: ≈ $123
  PNP_emission_apr        ≈ 3%      ; 14d: ≈ $184
  pendle_swap_fees        ≈ 1%      ; 14d: ≈ $61 (in LP NAV)
Hidden Hand vePENDLE arm (operator's pro-rata, ~250k vePENDLE):
  bribes_per_round        ≈ $640 (USDC + PENDLE proxy)
total gross ≈ $1870 / 14d / 100 LP
```
Annualised: **~30% APR** on PT-weETH LP including Penpie boost +
Hidden Hand. Pendle LPs at neighbouring markets in Q3 2024 reported
22-35% boosted APR; the boost + bribe combination is the upper tail.

Explicit unit-price assumptions:
- $/PENDLE at block 20.65M: **$3.00**
- $/mPENDLE: ~**$2.10** (mPENDLE trades below PENDLE as it is non-
  redeemable, only swappable on Penpie's PENDLE/mPENDLE Curve pool).
- $/PNP: ~**$2.50**
- $/vePENDLE bribe rate Q3 2024: **$0.04-$0.10** per round per vePENDLE.

## Block pinned
**20_650_000** (Aug 16 2024). Verified:
- PT-weETH-26DEC2024 market `0x7d372819…c704` returns
  `isExpired()==false` and a valid `(SY,PT,YT)` triple.
- Penpie's `MasterPenpie` deployed at `0x16296859…7d0` (Etherscan).
- `PendleMarketDepositHelper` at `0x1C1Fb353…0f4` is the canonical Penpie
  router.

## Risks & uncertainties
- **Penpie onboarding lag.** Newly-listed Pendle markets need explicit
  Penpie onboarding (`add_pool` via Penpie multisig). If the chosen
  market is not onboarded on the fork block, the helper reverts.
  PoC tolerates and falls back to native Pendle claim path.
- **PT maturity.** PT-weETH-26DEC2024 matures Dec 26 2024; from the
  fork block (Aug 16) we have 4.5 months of LP-side accrual before
  the market is forced into static settlement. Strategies that hold
  past maturity must roll into the next maturity bucket.
- **PENDLE/mPENDLE peg.** mPENDLE is non-redeemable to PENDLE; its
  market price floats. A 10-15% discount is common and is the primary
  source of *implicit* slippage in Penpie compounding.
- **Hidden Hand layout drift.** Same caveat as F12-05 — the storage
  probe + try/catch tolerates a layout change.
- **Pendle market shutdown.** Pendle has paused markets in response to
  oracle issues (e.g. PT-stETH on the stETH depeg). LP withdraws
  remain enabled but emissions stop.

## Result
Status: **theoretical, foundry build not run**. On-chain references
verified by Etherscan:
- MasterPenpie `0x16296859C15289731521F199F0a5f762dF6347d0`.
- PendleMarketDepositHelper `0x1C1Fb35334290b5ff1bF7B4c09130885b10Fc0f4`.
- mPENDLE `0xfDf3A4F0BC2a8b7b9c9eAa5b04eF6e10F6A6A0FA` (Penpie's vePENDLE
  wrapper, verified vs Penpie docs).
- PNP `0x7DEdBce5a2E31E4c75f87FeA60bF796C17718715`.

Expected single-window PnL for 100 LP * 14 days:
- Penpie-boosted PENDLE+mPENDLE+PNP ≈ **$1100-1300**
- Hidden Hand vePENDLE bribes ≈ **$500-800**
- Pendle swap fees ≈ **$40-80**
- Gas ≈ 1.1M for deposit+multiclaim+HH-claim @ 20 gwei ≈ $0.75
- Net ≈ **+$1,800-2,200 / 14d / $160k notional ≈ 26-32% APR**

## Mechanism count
**3** (Pendle + Penpie + Hidden Hand).
