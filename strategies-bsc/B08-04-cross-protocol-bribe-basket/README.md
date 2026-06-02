# B08-04: veTHE + veCAKE cross-protocol bribe basket on slisBNB/BNB

## Mechanism
Same underlying pool — Lista's slisBNB/BNB pair — has gauges on **both**
Thena and PancakeSwap. Lista (or any party that wants the slisBNB pool
deep) bribes both gauge controllers each epoch because emissions on both
DEXs make the pool more attractive to passive LPs. A voter who locks
**both** veTHE and veCAKE captures the union of bribes for the same
underlying productive activity.

Three primitives stacked:

1. **veTHE** — already covered in B08-02 — locks THE, votes on Thena
   slisBNB/WBNB gauge.
2. **veCAKE** — Pancake's equivalent. CAKE locked for up to 4 years
   produces a non-transferable balance used by `GaugeVoting` to direct
   CAKE emission across PCS v2/v3 pools. PCS also has its own bribe
   market (`RevenueSharingPool` + Cakepie/StakeDAO wrappers); we model
   the canonical PCS GaugeVoting native bribe path.
3. **Bribe-basket aggregator** — single test contract holds both NFTs,
   votes both for the same target pool, claims both bribe streams
   in the same epoch boundary.

The strategy quantifies the **incremental $/vote** captured by adding the
second leg: if veTHE alone earns $0.012/vote and veCAKE alone earns
$0.008/vote, the combined position earns $0.020/vote on the same
underlying alpha thesis (Lista wants the pool deep on every DEX).

## Why it composes
- Lista's bribe budget is split across DEXs precisely because LPs use
  whichever DEX has higher gauge APR. A voter on **both** DEXs is
  effectively paid twice for the same act of "directing emissions to my
  pool" — pure economic free lunch up to the marginal cost of locking
  both tokens.
- veTHE and veCAKE have orthogonal token risk: veCAKE bears CAKE beta,
  veTHE bears THE beta. The combined position is therefore *less*
  concentrated in any single governance token than doubling-down on one.
- BSC voters who can run both protocols natively are rare; bribe markets
  on both sides have not arbitraged the price differential away.

## Preconditions
- veTHE + veCAKE both unpaused at pinned block.
- Both Thena Voter and PCS GaugeVoting have slisBNB/BNB gauges live.
- Bribe markets on both sides have pending USDC + lisUSD rewards from
  Lista's epoch budget.

## Strategy steps
1. Seed wallet with 100 000 THE and 200 000 CAKE.
2. **Thena leg**:
   - Approve THE → veTHE.
   - `create_lock(100_000e18, 2y)` → `theTokenId`.
   - Vote 100 % on slisBNB/WBNB Thena gauge.
3. **PCS leg**:
   - Approve CAKE → veCAKE.
   - `createLock(200_000e18, 4y)` (PCS uses 4 years max).
   - Vote 100 % on slisBNB/BNB PCS gauge via `GaugeVoting.voteForGaugeWeights`.
4. Warp 7 days (one Thursday→Thursday epoch).
5. Claim bribes:
   - Thena: `Voter.claimBribes(externalBribe, [USDC, lisUSD], theTokenId)`.
   - PCS: `RevenueSharingPool.claim(targets, tokens)` or via bribe market
     wrapper (e.g. Cakepie's `claimBribes`).
6. Off-ramp both batches to USDT for clean PnL.

## Numbers (assumed THE=$0.30, CAKE=$2.40)
- veTHE leg notional: 100k × $0.30 = $30 000. Bribe $/vote: **$0.012**.
  Votes ≈ 100k (full 2y lock). Bribes/week = $1 200.
- veCAKE leg notional: 200k × $2.40 = $480 000. Bribe $/vote: **$0.0008**
  (PCS GaugeVoting is bigger and more diluted than Thena). Votes ≈ 200k
  (4y full lock). Bribes/week = 200k × 0.0008 = **$160**.
- Combined: $1 200 + $160 = **$1 360 / week**.
- Capital deployed (locked principal at-risk): $30k + $480k = **$510k**.
  → 0.27 % weekly = **14 % APR gross**.
- Note the *incremental* veCAKE yield is poor (3 % APR on its $480k leg)
  but the position is interesting because it amplifies a thesis already
  paid for by the veTHE leg.

## Trade-off observation
- veTHE leg alone: $1 200 / $30k = **208 % APR**.
- Adding veCAKE leg: marginal $160 / $480k = **1.7 % APR** on the
  additional capital. **NOT a $/vote efficient deployment** if you
  already hold the veTHE position.
- → The honest conclusion: cross-protocol stacking is only profitable
  when veCAKE-side bribes are abnormally high (e.g. when Lista runs a
  Cakepie campaign). In normal weeks the second leg is a money loser
  relative to keeping the CAKE liquid.

## Risks not modelled
- Same as B08-02 (THE / CAKE price moves), doubled because two governance
  tokens are locked simultaneously.
- veCAKE liquidity is tighter than veTHE — early exit via Cakepie
  secondary market trades at 20–30 % discount.

## TODO
- Verify PCS `veCAKE`, `GaugeVoting`, and `RevenueSharingPool` addresses
  at the pinned block. Currently `LOCAL_VE_CAKE` and `LOCAL_PCS_GAUGE_VOTING`
  are guess-and-verify placeholders.
- Confirm PCS bribe market topology (native GaugeVoting vs Cakepie vs
  StakeDAO/Penpie-style wrappers) for the BSC chain. Pendle's Penpie
  model is the most likely wrapper for organised bribe markets.
- Implement true $/vote scanner across both protocols and only deploy
  when combined yield > single-leg yield.
