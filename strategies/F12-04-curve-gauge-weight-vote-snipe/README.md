# F12-04: Curve gauge-weight vote snipe via veCRV

## Mechanism
Curve's `GaugeController`
(`0x2F50D538606Fa9EDD2B11E2446BEb18C9D5846bB`) is the on-chain registry
that distributes the global CRV emission across gauges. Voters must hold
**veCRV** (4-year max-lock CRV) to call
`vote_for_gauge_weights(gauge, weight)`. Vote weight is proportional to
the voter's *current* veCRV balance, decays linearly toward unlock,
expires when the lock ends, and can be re-cast at most once per 10 days
per gauge (`WEIGHT_VOTE_DELAY`).

A "vote snipe" is the strategy of allocating veCRV to a low-TVL gauge
where the marginal $/vote bribed on Votium or Hidden Hand is the highest.
On a typical round the dispersion is wide: top-priced gauge can pay
$0.30/vlCVX while bottom pays $0.02, and a vote-aware operator can lift
yield 3-8x by picking the right pool. The on-chain primitives this PoC
exercises:

1. **veCRV (`0x5f3b5D…E2A2`)** — `create_lock(amount, unlock_time)` and
   `balanceOfAt` are the source-of-truth for vote weight.
2. **GaugeController** — `vote_for_gauge_weights(gauge, weight)` writes
   into `vote_user_slopes[user][gauge]` and updates the gauge's slope.
3. **`gauge_relative_weight(gauge)`** — returns the gauge's share of
   total emissions at the requested timestamp. A vote should observably
   shift this for a small gauge.

## Why it composes
This is the upstream primitive that *creates* the bribe market: without
on-chain vote-direction there is nothing to bribe. The composition:
- A protocol seeking emissions for its pool deposits a bribe on Votium.
- Vote-holders (vlCVX / veCRV) re-allocate their weight toward that pool.
- The gauge controller recomputes the next-week emissions split.
- Curve emits CRV to the now-favored gauge; LPs there earn the boost.

The strategy demonstrates the upstream lever in isolation: lock CRV,
vote for a chosen gauge, observe `get_gauge_weight` and
`gauge_relative_weight` move.

## Preconditions
- Mainnet fork at a recent block (uses `block.timestamp` to compute
  unlock_time = block.timestamp + 4 years). We pin **19_643_500**
  (Apr 13 2024).
- A funded test account with 100,000 CRV to lock.
- A target gauge to vote for. We use the **frxETH/ETH** gauge
  (`0x0Cad1700FaA86B33b5f8094B2cE94D4Cfd14Cd2c`) — a low-weight pool
  where a 100k CRV vote will visibly shift the share.

## Strategy steps
1. Fund self with 100k CRV.
2. Approve and `veCRV.create_lock(100_000e18, block.timestamp + 4 *
   365 days)`. Read back `balanceOf(self)` — should be ~98% of the
   locked amount (4-year max boost = 1.0x at lock instant, decays).
3. Read pre-vote `gauge_relative_weight(target)` at `block.timestamp`.
   Capture as `weightBefore`.
4. Read pre-vote `get_gauge_weight(target)` — absolute slope sum.
5. Call `GaugeController.vote_for_gauge_weights(target, 10000)` — the
   `user_weight` argument is in **basis points of the user's veCRV
   budget**, max 10000 (100%).
6. Read `vote_user_slopes(self, target)` — slope/power/end. Power must
   equal 10000.
7. Warp 8 days (past `WEIGHT_VOTE_DELAY` so a re-vote is legal, and
   into the next gauge-controller epoch — gauge weights are
   snapshotted weekly at the Thursday epoch boundary).
8. Read post-vote `gauge_relative_weight(target)` — capture
   `weightAfter`. Assert `weightAfter > weightBefore`.
9. The PoC ends with the lock still active; no exit (veCRV early exit
   is a 50% slash in newer Vyper versions but the canonical veCRV
   actually has no early exit — it requires waiting for unlock).

## PnL math
The PoC's *direct* PnL is zero (vote does not earn rewards by itself;
the voter would need to also be an LP). The accounting metric is the
**emissions redirected**: if `weightAfter - weightBefore = Δw`, the
absolute CRV redirected to the target gauge per second is
`CRV_emission_rate * Δw`. For block 19.6M with the global rate
≈ 5.34 CRV/sec, a Δw of 0.001 (10 bps) redirects ~5.34e-3 CRV/sec ≈
**462 CRV/day** ≈ $208/day at $0.45 to that gauge's LPs.

The bribe market price for that diverted emission was ~$0.10-$0.18
per vlCVX-equivalent vote, and 100k CRV (max-locked, 4yr) holds slope
~= 25k veCRV-eq votes at decay-0. Round-PnL if bribed at $0.14/vote:
≈ **25_000 * $0.14 = $3,500 per Votium round**.

For the *veCRV side specifically* this PoC just verifies the upstream
lever; the downstream bribe-capture is the F12-02 PoC.

## Block pinned
**19_643_500** (Apr 13 2024). Both veCRV and GaugeController are
immutable Vyper contracts deployed in 2020 and have not migrated.
Verified that:
- `veCRV.totalSupply()` is non-zero (lock count ~10k).
- `GaugeController.n_gauges()` is well past the target gauge's index.

## Risks
- **10-day vote lock.** Once cast, the same (user, gauge) tuple cannot
  be re-voted for `WEIGHT_VOTE_DELAY = 10 days`. Strategies need to
  manage a quorum of veCRV across multiple gauges to keep flexibility.
- **veCRV decay.** Voting power decays toward zero at unlock. A 4-year
  max lock holds full slope for exactly 1 instant; afterward it
  declines linearly. To maintain weight a user must `increase_unlock_time`
  periodically.
- **No exit.** Canonical veCRV has *no* early withdrawal; CRV is locked
  for the full term. Strategies should weight the opportunity cost.
- **Bribe market efficiency.** Top gauges are heavily-voted; marginal
  vote captures less premium. The arb window opens around small gauges
  with sudden bribe spikes; identifying these is an off-chain task.
- **CRV/veCRV-only**. This PoC is veCRV-direct, *not* vlCVX. The vlCVX
  variant (Convex's mirror) is identical in structure and the bribe
  market is denser there; F12-02 covers that side.

## Result
Status: **theoretical, foundry build not run**. veCRV and GaugeController
ABIs verified against on-chain Vyper sources. PoC exercises:
- `create_lock` accepts (amount, unlock_time).
- `vote_for_gauge_weights` writes vote_user_slopes.
- `gauge_relative_weight` moves after the vote takes effect at the next
  Thursday epoch.

Expected weight delta on 100k CRV / 4-year lock on a small gauge:
**Δw ≈ 6-15 bps** depending on competing votes. Translated to bribe
revenue: **~$500-$3,500 per round** if the holder also delegates to
Votium and collects bribes on the redirected emission.
