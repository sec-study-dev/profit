# B08-06: veTHE + Pendle YT-THE + Thena LP combo (3-mechanism)

## Mechanism
Treasury of 1 000 000 THE tokens is split across three orthogonal
yield-extraction primitives that all derive from THE:

1. **ve(3,3) governance** (50 % = 500k THE) — locked 2y → veTHE NFT →
   vote on slisBNB/WBNB gauge → claim weekly bribes ($0.012/vote).
2. **Pendle YT-THE** (30 % = 300k THE) — wrap into SY-veTHE, split into
   PT and YT. Sell PT at par for USDC (Pendle implied yield ≈ 0 % over
   90 days on veTHE points), retain YT to capture residual bribe
   cashflow without committing to a full 2y lock.
3. **Thena LP gauge** (20 % = 200k THE) — pair with WBNB into the
   THE/WBNB volatile LP → gauge stake → THE emissions at ~60 % APR.

## Why it composes
- **Different lock terms exposure**: veTHE locks 2 years, YT runs 90 days,
  LP can exit instantly. The 50/30/20 mix matches a typical THE treasury's
  liquidity preference — earn voter bribes on the half you'd lock anyway,
  earn YT carry on the third you're undecided about, keep the rest
  productive but exitable.
- **Yield sources are independent**: voter bribes pay $/vote, YT pays
  $/THE/week via veTHE-yield SY, LP pays THE emissions on TVL. Adding
  one doesn't dilute the others.
- **PT sale is the trick**: by selling PT at par we **monetise the
  optionality premium** of Pendle's YT pricing. If Pendle's YT trades at
  50 % of fair carry, the half not captured by YT is captured by the PT
  buyer — but we don't care because the PT sale recovers principal.

## Preconditions
- veTHE accepts new locks (always true except during emergency pause).
- Pendle YT-THE / SY-veTHE market exists at the pinned block. *Not yet*
  on BSC at FORK_BLOCK 40_000_000; this strategy is the **roadmap** for
  when Penpie / Equilibria deploys a veTHE wrapper. PoC uses modeled
  carry until then.
- Thena THE/WBNB volatile gauge live with non-zero rewardRate.

## Numbers (THE=$0.30, BNB=$600)
- Total notional: 1M THE × $0.30 = **$300 000**.
- Sub-allocations:
  - veTHE 500k THE → 500k votes (full 2y lock @ max-lock balanceOfNFT).
  - YT-THE 300k THE → 300 × YT-units, 90-day expiry.
  - LP-THE 200k THE + 100k THE-equivalent BNB = $120k LP notional.
- Weekly yields:
  - veTHE bribes: 500k × $0.012/vote = **$6 000 / week**.
  - YT carry: 300k × $0.006/THE/wk = **$1 800 / week**.
  - LP emissions: $120k × 60 % × 7/365 = **$1 381 / week** =
    4 603 THE.
  - LP fees: modeled negligible on the thin THE/WBNB book (skipped).
- **Combined: $9 181 / week ≈ 159 % APR on $300k.**

## Trade-off observation
- veTHE-only on 1M THE: 1M × $0.012 = $12k/wk = **208 % APR**.
- Adding YT+LP gives up 50 % of bribe yield to gain liquid optionality.
- Strategy is **better** than pure veTHE when:
  - You expect THE price to rally (LP captures upside, veTHE doesn't).
  - You're uncertain about 2y lock commitment (YT exit at 90d).

## $/THE primary metric
- veTHE leg: **$0.012/THE/wk** (locked).
- YT leg: **$0.006/THE/wk** (90-day exposure).
- LP leg: implicit $0.0023/THE/wk in emission + share of LP fee tail.
- Blended: $9 181 / 1 000 000 = **$0.00918/THE/wk**.

## Risks not modelled
- Pendle YT-THE market does not exist yet at pinned block — the YT leg
  is a modeled placeholder. If Penpie launches at $0.50/THE for YT
  (instead of $0.30 par for PT), the assumed PT par sale is wrong.
- THE price tail risk applies to **all three legs** simultaneously.
- LP impermanent loss against THE/WBNB swing — modeled fees ignore this.

## TODO
- Resolve `LOCAL_PENDLE_YT_THE_MARKET` when Penpie / Equilibria deploys a
  veTHE SY wrapper on BSC.
- Replace modeled PT/YT split with `IPendleRouter.mintPyFromToken` + sell
  PT via `swapExactPtForToken` once market is live.
- Add hedge: short THE perp on a CEX to neutralise treasury THE-price
  exposure while harvesting yield in stables.
