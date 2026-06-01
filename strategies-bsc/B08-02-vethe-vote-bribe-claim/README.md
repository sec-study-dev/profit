# B08-02: veTHE lock → vote highest-bribe gauge → claim bribes

## Mechanism
Pure ve(3,3) voter strategy. Lock THE → receive a veTHE NFT → use the NFT's
voting weight to direct THE emissions toward a specific gauge → in return,
collect the bribes that the gauge's bribe-payer has deposited on the
`externalBribe` contract for that epoch.

Three coordinated primitives:

1. **veTHE** — Curve-style voting escrow NFT (ERC-721). `create_lock(amount,
   duration)` mints an NFT whose voting weight decays linearly until expiry.
   Max lock is 2 years; voting weight at time `t` is roughly
   `amount * remaining / MAX`.
2. **IThenaVoter.vote** — assigns the NFT's voting weight across one or more
   pools. Vote is binding for the current epoch (Thursday → Thursday) and
   sticky until `reset` or re-vote.
3. **externalBribe contract** (per gauge) — bribers `notify_reward_amount`
   each Wed/Thu; voters claim `pro-rata of voting weight` after epoch close.

The strategy locks a known THE balance, identifies the gauge whose
`$/vote` ratio (bribes paid this epoch / total votes already cast) is
highest, votes 100 % of its weight there, warps to next epoch, then claims
via `IThenaVoter.claimBribes`.

## Why it composes
- Bribe payers (Lista, Frax, Ondo, etc.) post bribes *before* votes close,
  so the voter can choose the highest-yielding gauge with full information.
  Provided the total vote pool is not dominated by a single counter-voter
  pushing in late, the realised $/vote is close to the snapshot.
- The veTHE NFT can be re-voted next epoch without unlocking, so the same
  lock is reused weekly. PoC simulates one epoch; APY annualises 52×.
- External bribes arrive in arbitrary ERC-20s (commonly USDC, USDT, lisUSD,
  WBNB, the protocol's own token). The voter incurs token-management risk
  but is otherwise unilaterally entitled to its slice.

## Preconditions
- veTHE contract is unpaused, accepts new locks at the pinned block.
- At least one `externalBribe` contract has non-zero pending USDC/USDT
  rewards before vote cut-off.
- `IThenaVoter.bribes(gauge)` returns a valid `(internalBribe,
  externalBribe)` tuple.

## Strategy steps
1. Seed wallet with 100 000 THE (≈$30k @ $0.30).
2. Approve THE → veTHE; call `create_lock(100_000e18, 2 * 365 days)` →
   receive NFT id `tokenId`.
3. Pick target pool — for the PoC, slisBNB/WBNB (same gauge as B08-01).
   In production the chooser scans every gauge's externalBribe pending
   balance and computes $/vote.
4. `Voter.vote(tokenId, [pool], [10_000])` — 100 % weight to that pool.
5. Warp 7 days (one epoch). Bribers are assumed to have posted a known
   USDC + lisUSD bribe to the externalBribe over the epoch.
6. `Voter.claimBribes([externalBribe], [[USDC, lisUSD]], tokenId)`.
7. Optionally re-vote next epoch (out of scope for single-epoch PoC).
8. Print PnL (USDC + lisUSD gained; THE still locked, marked at $0.30).

## Numbers (assumed at $0.30/THE, $1/USDC, $1/lisUSD)
- Lock: 100 000 THE × $0.30 = $30 000 notional, 2-y lock ≈ full
  voting weight = 100 000 votes (linear decay irrelevant in epoch 0).
- Assumed $/vote for target gauge this epoch: **$0.012**
  (i.e. $12 of bribes per 1 000 votes — current Thena average).
- Bribe collected: 100 000 votes × $0.012 = **$1 200 / week**.
- Split assumed 60 % USDC ($720) + 40 % lisUSD ($480).
- Annualised: $1 200 × 52 = $62 400 on $30k of locked value ≈ **208 % APR**
  (gross, before claim gas and THE price risk).
- Gas: ~6 calls × 200k @ 1 gwei × $600/BNB ≈ $0.72.

## Risks not modelled
- THE price volatility — lock is 2 years, mark-to-market on THE swings 1:1.
- Voting-decay mid-lock: as remaining time shrinks, the $/vote yield drops.
- Bribe payers can post in the last block, diluting realised $/vote.
- Bribe tokens often have low liquidity (e.g. small DeFi tokens); the PoC
  assumes USDC + lisUSD which are easily off-ramped.

## TODO
- Verify `veTHE.create_lock(uint256,uint256)` signature; some Solidly forks
  use `(uint256 value, uint256 lock_duration)` with seconds, others use
  weeks.
- Verify `claimBribes` signature; the interface lists `(bribes_, tokens,
  tokenId)` but some Thena versions inverted the order. The PoC's
  externalBribe address is captured before warping for safety.
- Real $/vote scanner needed to pick the optimum gauge — currently
  hard-coded to slisBNB/WBNB.
