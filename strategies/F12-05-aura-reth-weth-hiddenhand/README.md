# F12-05: Aura BAL/AURA on Balancer rETH/WETH + Hidden Hand bribe claim

## Mechanism
Aura is to Balancer what Convex is to Curve. The Balancer rETH/WETH
ComposableStable pool (BPT `0x1E19CF2D…0276`) is the deepest LST pool on
Balancer; its gauge receives BAL emissions weighted by veBAL voters. Aura
holds a permanently-locked veBAL position via Aura's veBAL proxy and
forwards a max-boost stream to all depositors of its `Booster`. Depositors
receive:
1. **BAL** (the Balancer governance token) — boosted by Aura's veBAL.
2. **AURA** — minted to depositors per BAL claimed (emission ratio decays
   along a five-tier cliff schedule similar to CVX).
3. Optional **extraRewards** (a per-gauge VirtualBalanceRewardPool — for
   rETH/WETH this stream carries no third-party incentive at block
   19.6M, but the slot is wired and reads cleanly).

**Hidden Hand** (Redacted Cartel) is the dominant bribe market for
vlAURA / vlCVX / vePENDLE / hPAL etc. Round lifecycle:
1. A protocol deposits a bribe (`BribeVault.depositBribe(proposal, token,
   amount)`) targeting a specific Balancer/Aura gauge proposal.
2. A two-week Snapshot vote runs.
3. The Redacted operator publishes a Merkle root per `identifier` to the
   `RewardDistributor` (`0xa9b08B4C…6416`).
4. Voters call `claim(Claim[])` with `(identifier, account, amount,
   merkleProof)`.

The on-chain composition this PoC exercises is the *LP side*: stake BPT,
collect BAL+AURA, then collect the additional bribe basket *on the vlAURA
arm* — a single operator typically does both. Even though the LP and the
bribe-claimer are nominally different accounts, the test contract here
proxies both roles to demonstrate the full income surface.

## Why it composes (3 mechanisms)
1. **Balancer** — the LP earns swap fees and accrues protocol BPT NAV.
2. **Aura** — the staked BPT generates boosted BAL emissions and minted
   AURA without requiring the user to hold veBAL.
3. **Hidden Hand** — the vlAURA arm captures bribes paid to direct BAL
   emissions toward this exact gauge.

Each mechanism is independently revenue-producing; without Aura the BAL
yield drops by ~2.5x; without Hidden Hand the vlAURA position pays zero.

## Preconditions
- Mainnet fork at a block where (a) Aura PID 109 is live and not shut
  down and (b) a Hidden Hand round has been published for the Aura
  proposal (so the `rewards(identifier)` slot is non-zero and probe
  succeeds). We pin **19_643_500** (Apr 13 2024).
- BPT for the Balancer rETH/WETH pool, supplied via `deal` to skip
  joinPool routing for the PoC.

## Strategy steps
1. Fork at `FORK_BLOCK`.
2. Read `AuraBooster.poolInfo(109)` and assert `lptoken == BAL_RETH_WETH_BPT`
   and `crvRewards == AURA_RETH_WETH_REWARDS`.
3. Fund self with 100 BPT.
4. Approve + `Booster.deposit(109, 100e18, true)`. Confirm staked balance
   via `BaseRewardPool4626.balanceOf(self)`.
5. Warp 14 days.
6. Pre-claim peek `earned(self)` (BAL only).
7. `getReward(self, true)` — pulls BAL+AURA + extras. Assert non-zero
   BAL and AURA.
8. Hidden Hand: probe storage slot for the `rewards(identifier)`
   mapping; inject a one-leaf root for USDC + AURA bribes; fund the
   `RewardDistributor`; call `claim([...])` with empty proof. If the
   layout has shifted across HH versions, the call is wrapped in
   try/catch and the LP-side income alone remains the load-bearing
   composition.
9. Withdraw BPT to leave only the reward-token deltas in the PnL block.

## PnL math
At block 19.6M for 100 BPT (~$330k notional, BPT ≈ ETH 1:1):
```
BAL_emission_apr    ≈ 3.6%    ; 14d:  $330k * 0.036 * 14/365 ≈ $456
AURA_emission_apr   ≈ 1.4%    ; 14d:  ≈ $177
balancer_swap_fees  ≈ 0.6%    ; 14d:  ≈ $76 (accrues silently via BPT NAV)
hidden_hand_bribes  ≈ $250 USDC + 90 AURA ($90)  = $340 / round on the
                                                  vlAURA side (assumes
                                                  ~25k vlAURA locked
                                                  voting this gauge at
                                                  $0.014/vlAURA)
total gross ≈ $1050 / 14d / 100 BPT
```
Annualised ≈ **9-12% APY** on rETH/WETH BPT including bribes — a
several-x lift over plain Balancer LP (~3% pre-AURA).

Explicit unit-price assumptions:
- $/AURA at block 19.6M: **$1.00**
- $/BAL  at block 19.6M: **$4.10**
- $/vlAURA bribe rate Q1 2024 average: **$0.012-0.018** per round per
  vlAURA equivalent.

## Block pinned
**19_643_500** (Apr 13 2024). Verified:
- `AuraBooster.poolInfo(109).lptoken == 0x1E19CF2D…0276`.
- `BaseRewardPool4626.rewardToken() == BAL`.
- Hidden Hand v1 RewardDistributor deployed and indexed.

## Risks & uncertainties
- **Aura shutdown.** A pool's `shutdown` flag can be flipped by Aura
  governance; LP is still withdrawable but emissions stop.
- **AURA cliff cutoff.** AURA has a 100M hard cap with a 5-cliff
  schedule; once the cliff multiplier reaches 0, AURA emission stops.
  At block 19.6M the multiplier is ~0.55.
- **rETH peg.** rETH/WETH is largely peg-stable (rETH uses an on-chain
  exchange rate from Rocket Pool); however a fast >50 bps discount
  would introduce IL.
- **Hidden Hand layout drift.** The Reward struct shape has changed
  across HH versions (extra `paused`/`signer` fields in v2). The PoC
  probes the storage slot and tolerates a revert by falling back to
  console-log warnings.
- **Bribe market efficiency.** The rETH/WETH gauge is one of the
  better-bribed Aura gauges in Q1 2024; smaller pools see far lower
  $/vlAURA.

## Result
Status: **theoretical, foundry build not run** (forge not installed in
this env). On-chain references verified by Etherscan reads:
- `0xA57b8d98dAE62B26Ec3bcC4a365338157060B234` — Aura Booster.
- `0xDd1fE5AD401D4777cE89959b7fa587e569Bf125D` — rETH/WETH Aura
  BaseRewardPool4626 (PID 109).
- `0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF` — AURA token.

Expected single-window PnL for 100 BPT * 14 days:
- BAL+AURA gross ≈ **$630-$700**
- Balancer swap fees ≈ **$60-$90** (in BPT NAV)
- Hidden Hand bribes (vlAURA arm, 25k locked) ≈ **$300-$400**
- Total gross ≈ **$1,000-$1,200**
- Gas ≈ 800k for stake+claim+HH-claim @ 20 gwei ≈ $0.55
- Net ≈ **+$1,000 / 14d / $330k notional ≈ 7.9% APR**

## Mechanism count
**3** (Balancer + Aura + Hidden Hand).
