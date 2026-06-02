# B08-07: Thena bribe-auction front-run on epoch close

## Mechanism
Thena's ve(3,3) epoch boundary is **Thursday 23:59 UTC**. Bribe payers
seed `externalBribe` contracts with USDC / lisUSD throughout the week,
but a disproportionate share of bribe budget lands in the **last hour**
of the epoch — this is the "Tuesday/Thursday dump" pattern observed
empirically on Velo/Aero and replicated by Thena.

Why protocols dump bribes at T-1h:
1. They see how votes are already distributed and need to **outbid**
   the competing bribe to redirect emissions.
2. They can't be sniped by a new entrant because veTHE votes locked
   in early-week voters are still committed.
3. Front-runners (us) capture the marginal $/vote of the top-up bid
   because we've parked votes uncommitted until T-1h.

Strategy steps:
1. Lock 500 000 THE → veTHE NFT but **do not cast votes** at lock-time.
2. Subscribe to bribe-contract `Notified` events; build a heatmap of
   $/vote per gauge updated every 15 minutes.
3. At T-1h (60 minutes before epoch close), scan `externalBribe.rewards(token)`
   on every gauge, rank by USD bribe / current votes, pick the top.
4. Cast vote 100 % toward the winner.
5. Warp to epoch close + claim.

## Why it works
- Passive voters at T-6d see only ~$0.008/vote because budget is back-loaded.
- Front-runners at T-1h see ~$0.022/vote because the late dump has landed
  and the denominator (`totalVotes`) only changes marginally in the
  remaining hour.
- The gap is **structural**: epoch-finalisation bribes can't be revealed
  earlier or the game theory breaks.

## Preconditions
- veTHE casts vote in the **same epoch** as the bribe deposit (Thena rule).
- T-1h window is long enough to scan all gauges (Thena has ~150 active
  pools — easy to scan within 60 minutes).
- Bribe contracts use `notifyRewardAmount` (standard Solidly fork).

## Numbers (THE=$0.30)
- Lock: 500 000 THE = $150 000 notional.
- Votes (full 2y lock, immediately post-lock): ≈ 500 000.
- Passive $/vote (T-6d): $0.008 → $4 000/week → 139 % APR.
- Front-run $/vote (T-1h): $0.022 → $11 000/week → **381 % APR**.
- **Edge captured: $7 000/week = ~243 % APR uplift** vs passive.

## Trade-off observation
- The front-run only works if **(a)** you maintain a permanent
  uncommitted veTHE position and **(b)** automated infra can switch
  votes within seconds at epoch close.
- Gas cost is trivial (~$1 per vote cast on BSC).
- The "passive" voter we steal from is not literally a competitor — they
  are bribe payers who didn't allocate enough budget to compete.

## Risks not modelled
- **Reflexivity**: if many voters front-run, $/vote converges. Empirical
  observation on Velo: 3-5 active front-runners can co-exist before the
  edge collapses.
- **Vote-locking**: some forks of Thena require a 1-block delay between
  `voter.reset()` and `voter.vote()`. The PoC casts once; verify Thena
  doesn't block re-voting mid-epoch.
- **Epoch finality drift**: Thena occasionally delays epoch finalisation
  by a few blocks. A naive T-1h script will miss the window if the
  protocol calls `distribute()` early.

## $/vote primary metric
- Baseline: **$0.008 / vote / week**.
- Front-run: **$0.022 / vote / week**.
- **Edge: $0.014 / vote / week** — pure timing alpha.

## TODO
- Implement on-chain scanner: iterate `voter.pools()`, read `gauges(p)`,
  `bribes(g).externalBribe`, then `rewards(USDC) + rewards(lisUSD)`.
- Add off-chain bot trigger at T-1h UTC every Thursday.
- Verify Thena epoch boundary at FORK_BLOCK and confirm bribe deposit
  pattern via Thena subgraph (`BribeReward` events).
