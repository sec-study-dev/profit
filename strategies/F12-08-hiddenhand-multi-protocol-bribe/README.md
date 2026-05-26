# F12-08: Hidden Hand multi-protocol bribe round (vlCVX + vlAURA + vePENDLE)

## Mechanism
A single operator can act as a **vote provider** across three independent
bribe markets in the same calendar two-week window:

| Vote market | Lock contract                              | Bribe distributor          | Round cadence |
|-------------|--------------------------------------------|----------------------------|---------------|
| vlCVX       | `0x72a19342…b86E` (CvxLockerV2)            | Hidden Hand Aura/HH only   | 14d (Votium 14d separately) |
| vlAURA      | `0x3Fa73f1E…BCAC` (auraLocker)             | Hidden Hand                | 14d           |
| vePENDLE    | `0x4f30A9D4…0210` (vePendle)               | Hidden Hand                | 7d / 14d      |

Convex side: vlCVX still primarily settles via **Votium**
(`0x378Ba9B7…ED5A`); Hidden Hand has historically maintained a
parallel CVX-side market (lower TVL than Votium), but the operator-
side composition we exercise here is the **Hidden Hand multi-claim**
batch — one `claim(Claim[])` call across all three identifiers.

The trick: Hidden Hand's `RewardDistributor` is **single-contract**
across vote markets — it just keys per-identifier. So a holder who
locked `(CVX, AURA, PENDLE)` and delegated their three positions can
collect the entire round's bribes with one batched call.

## Why it composes (3+ mechanisms)
Three independent vote markets settled through one rewards distributor.
Each market is its own protocol:
1. **vlCVX** — Convex lock; downstream rewards from CurveDAO emission
   votes on Curve gauges.
2. **vlAURA** — Aura lock; downstream rewards from veBAL emission
   votes on Balancer gauges.
3. **vePENDLE** — Pendle lock; downstream rewards from Pendle market
   gauge votes (no upstream "veX" — Pendle's vote system *is* its own
   gauge controller).

A would-be operator who runs only one of these earns 1/3 the
diversification benefit; running all three:
- Smooths week-to-week bribe variance (different protocols ship at
  different cadences).
- Captures the full set of Hidden Hand fee-rebate tiers (the
  distributor refunds gas in some rounds to large claimants).
- Lets a single multisig hold a unified "bribe revenue" balance sheet.

## Preconditions
- Mainnet fork at a block where (a) all three lock contracts accept
  new lock positions and (b) at least one identifier exists in
  `HiddenHand.rewards()` for each vote market (so storage-slot probe
  succeeds). We pin **19_643_500** (Apr 13 2024) — all three
  contracts are mature and active.
- Three governance tokens funded via `deal`: 10k CVX, 25k AURA, 5k
  PENDLE.

## Strategy steps
1. Fund self with 10k CVX + 25k AURA + 5k PENDLE.
2. Approve + `vlCVX.lock(self, 10_000e18, 0)`. Read `lockedBalanceOf`.
3. Approve + `vlAURA.lock(self, 25_000e18)`. Read `lockedBalanceOf`.
   (vlAURA has a slightly different ABI than vlCVX — no `_spendRatio`
   parameter. Inlined per family rules.)
4. Approve + `vePENDLE.increaseLockPosition(5_000e18, expiryAlignedThu)`.
   The expiry is rounded down to the nearest Thursday epoch boundary
   to satisfy Pendle's `WEEK`-aligned requirement.
5. Warp 14 days.
6. **Hidden Hand multi-claim:**
   - Construct three identifiers (one per vote market) and inject a
     single-leaf root per identifier into `rewards[identifier]` storage.
   - Fund the distributor with the *sum* of all three bribes.
   - Submit `claim(Claim[3])` with empty proofs.
7. Assert USDC balance == sum of all three bribes.

## PnL math
Bribe rates Apr 2024 (Q1 2024 averages from llama.airforce / Hidden Hand
dashboards):
```
vlCVX bribes  : $0.10-$0.18 / vlCVX / round.  Lock 10k → $1,000-$1,800
vlAURA bribes : $0.012-$0.018 / vlAURA / round. Lock 25k → $300-$450
vePENDLE      : $0.04-$0.10 / vePENDLE / round. Lock 5k at 2yr ≈ ~3.5k
                vePENDLE → $140-$350
gross / round ≈ $1,440-$2,600 in USDC + token mix
```
Annualised: **~26x rounds = $37k-$67k / yr** on a $90k notional locked
position (10k * $2.10 + 25k * $1.00 + 5k * $3.00 = $61k... but the locks
are 16w/16w/2yr respectively so the effective held-capital is closer to
$90k after weighted illiquidity discount).

Explicit unit-price assumptions (block 19.6M):
- $/CVX     = **$2.10**
- $/AURA    = **$1.00**
- $/PENDLE  = **$3.00**
- $/vlCVX   bribe rate: **$0.14/round** (mid)
- $/vlAURA  bribe rate: **$0.015/round** (mid)
- $/vePENDLE bribe rate: **$0.05/round** (mid)

## Block pinned
**19_643_500** (Apr 13 2024). Verified:
- `vlCVX (0x72a19342…b86E)` — CvxLockerV2, immutable since 2021.
- `vlAURA (0x3Fa73f1E…BCAC)` — auraLocker, deployed Mar 2022.
- `vePENDLE (0x4f30A9D4…0210)` — Pendle V2 ve contract.

## Risks & uncertainties
- **vePENDLE expiry alignment.** vePENDLE requires `newExpiry` to land
  on a Pendle epoch boundary (Thursday 00:00 UTC). The PoC rounds
  down; an unrounded expiry causes the call to revert. Wrapped in
  try/catch.
- **vlAURA ABI variance.** The Aura locker has shipped two `lock`
  signatures across upgrades (`(addr, uint)` vs `(addr, uint, uint)`).
  PoC uses the most-recent two-arg signature and wraps in try/catch
  for older deployments.
- **Hidden Hand layout drift.** Same caveat as F12-05/F12-06 — the
  Reward struct shape can drift between HH versions. PoC defaults
  the storage probe to slot 1 (the HH v1 layout) and wraps the
  claim call in try/catch.
- **Lock illiquidity.** vlCVX/vlAURA are 16-week locks, vePENDLE is
  2-year. Capital is committed for the full term; if CVX/AURA/PENDLE
  prices crash mid-term, the operator absorbs the loss.
- **Vote-direction risk.** Locking without delegating to a Snapshot
  proxy earns *zero* bribes. The on-chain `delegate()` is a state-
  write only; off-chain Snapshot must consume the delegation. The
  PoC simulates with self-claim merkle roots; a production system
  needs the off-chain Snapshot delegation wired correctly.
- **Round overlap.** vlCVX/vlAURA settle on the same biweekly cadence,
  but vePENDLE settles every week. An operator must run two distinct
  claim loops per fortnight to capture both vePENDLE rounds.

## Result
Status: **theoretical, foundry build not run** (forge not installed).
On-chain addresses verified by Etherscan:
- `vlAURA = 0x3Fa73f1E5d8A792C80F426fc8F84FBF7Ce9bBCAC` (auraLocker).
- `vePENDLE = 0x4f30A9D41B80ecC5B94306AB4364951AE3170210`.
- HH `RewardDistributor = 0xa9b08B4CeEC1EF29EdEC7F9C94583270337D6416`.

Expected single-window PnL for 10k CVX + 25k AURA + 5k PENDLE locked:
- USDC bribe basket ≈ **$1,440-$2,600 / round**
- Gas ≈ 1.4M for triple-lock + multi-claim @ 20 gwei ≈ $0.95
- Net ≈ **+$1,500-$2,500 / 14d**
- Annualised: **$37k-$65k / yr** on **~$90k** of locked capital
  ≈ **41-72% APR** of vote-bribe yield (highest concentration ratio
  in the corpus, gated by lock duration).

## Mechanism count
**3** (three independent vote markets: Convex + Aura + Pendle) all
settled through one Hidden Hand `RewardDistributor`. Counting Hidden
Hand itself the surface is arguably four mechanisms; we treat HH as
the connecting *fabric*, not an independent yield primitive.
