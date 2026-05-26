# F15-06: EigenPod direct native restake (validator-level)

## Mechanism

EigenLayer's **native-restake** path is structurally distinct from its
LST-strategy path:

- **LST-strategy path (F15-01..05)**: deposit an ERC20 LST (stETH, rETH,
  cbETH…) into a per-asset `Strategy` proxy via `StrategyManager.depositIntoStrategy`.
  Shares are minted to the staker; the underlying LST sits in the strategy
  contract.
- **Native-restake path (this strategy)**: an Ethereum validator's withdrawal
  credentials point to an `EigenPod` contract the user owns. When the
  validator's beacon-chain balance is **proven** to the pod via a Merkle
  proof against `BeaconState`, EL credits the staker with beacon-chain-strategy
  shares equal to the proven balance. Those shares behave identically to
  LST-strategy shares for delegation, AVS rewards, and slashing.

The pod model:

```
[BeaconChain validator]
     | withdrawal_credentials = 0x01..00 || pod_address
     v
[EigenPod (per-user contract)]
     | verifyWithdrawalCredentials(...)
     v
[EigenPodManager bookkeeping]
     | credits beacon-chain-strategy shares to podOwner
     v
[DelegationManager.delegateTo(operator)]
```

## Why it composes

The compose value is **eliminating the LST wrapper fee** while still
participating in EigenLayer + AVS rewards.

Stacking on 32 ETH validator notional:

1. **Native CL rewards** — full validator issuance + tips, no LST cut.
   ~3.2-4.5% APR depending on network state and MEV capture.
2. **EigenLayer points + base AVS reward stream** — accrues to the
   beacon-chain-strategy share, same rate as LST strategies.
3. **(Once delegated)** operator-routed AVS rewards on the 32 ETH notional.

vs the Lido path on 32 stETH, the **delta**:
- Native: 100% of CL rewards (32 × 4.0% = 1.28 ETH).
- Lido: 90% of CL rewards to depositor (10% goes to node-operators+treasury);
  on 32 stETH that's 32 × 3.6% = 1.15 ETH.
- Delta: **~+0.13 ETH/yr per validator (~$390 @ $3k)**.

Annualised on 32 ETH ($96k) this is ~0.4% APR uplift — small but additive
to everything else stacked on top. The **real reason** to run native restake
is **slashing-condition isolation** — you choose your own validator, your
own AVS opt-ins; you are not exposed to Lido's node-operator selection or
re-key risk.

## Why this PoC is structural-only

`verifyWithdrawalCredentials` requires:

- A live beacon-chain validator with withdrawal credentials pointed at the pod.
- A current `BeaconState` SSZ Merkle proof keyed by `oracleTimestamp`.
- The proof verifier inside EigenPod cross-checks against `BEACON_ROOTS` (EIP-4788).

None of this is reproducible on a Foundry mainnet-execution-layer fork:
the EL-layer fork has no beacon-chain SSZ state, and the BeaconRootsOracle
contract returns 0 for arbitrary timestamps in fork conditions. The PoC
therefore exercises only the **call-shape** of the native path:

1. Create the pod via `EigenPodManager.createPod()`.
2. Verify ownership (`hasPod`, `ownerToPod`, `EigenPod.podOwner`).
3. Read pod-state views.
4. Document the remaining off-chain step.

## Preconditions

- Block: 20,500,000 (Aug 2024). EigenPodManager well-established.
- A fresh test address (no pre-existing pod). The PoC uses `address(this)`
  which is a fresh foundry test contract — guaranteed pod-less.
- EigenPodManager address: `0x91E677b07F7AF907ec9a428aafA9fc14a0d3A338`
  (verified via EL docs + Etherscan).

## Strategy steps (PoC scope)

1. `_fork(20_500_000)`.
2. Assert `epm.hasPod(address(this)) == false`.
3. `address pod = epm.createPod()` — deploys a new `EigenPod` clone.
4. Assert `epm.hasPod(address(this)) == true` and ownership round-trips.
5. Read `pod.withdrawableRestakedExecutionLayerGwei()` (should be 0 — no
   validator deposited yet) and `pod.mostRecentWithdrawalTimestamp()`.
6. Log the missing off-chain leg.

## PnL math (forward, 1 validator = 32 ETH notional)

```
Equity:      32 ETH (~$96k @ $3k ETH)
Holding:     1 year

(a) Beacon-chain CL rewards
    32 × 4.0% (mid-2024 avg incl. MEV) = 1.28 ETH ≈ $3,840

(b) EigenLayer native-restake points
    32 × 1 pt/ETH/day × 365 = 11,680 pts
    @ $3.50/pt (EIGEN listing assumption) ≈ $40,880

(c) Single AVS opt-in (e.g. EigenDA via a delegated operator)
    32 × 0.20% = 0.064 ETH ≈ $192

Total (no LST fee):  $3,840 + $40,880 + $192 ≈ $44,900 / yr / 32 ETH

Compare 32 stETH in EL stETH strategy:
    Lido path:     32 × 3.6% × $3k = $3,456 (Lido takes 10%)
  + Same EL pts:                    $40,880
  + Same AVS:                       $192
  Total:                           ≈ $44,500 / yr / 32 stETH

Delta vs LST: ~+$400/yr per validator (~+0.4% APR uplift).
```

The uplift is small **on cash terms** but the strategic value is:

- **No LST depeg risk.** stETH traded at -7% in May 2022; -2% in 2024.
- **No Lido governance risk.** Lido controls the node-operator set; native
  restake lets the user choose.
- **No queue contention.** Lido's withdrawal queue can backlog; native
  restake's withdrawal is the 0-32 ETH partial-exit + validator-exit path,
  governed only by the beacon chain.

## Block pinned

- Fork block: 20,500,000.

## Risks

- **Beacon-chain proof reproducibility.** As noted, the proof leg is NOT
  reproducible on a fork. Anyone running this in production must couple
  the foundry mechanics PoC with an actual beacon-chain validator + proof
  generator (e.g. `eigenpod-proofs-generation` from the EL repo).
- **Slashing condition exposure.** Native restake exposes the validator to
  the union of (beacon-chain slashing OR AVS slashing OR EigenLayer
  protocol slashing). Beacon-chain double-sign is the dominant historical
  fault; AVS slashing has not occurred as of FORK_BLOCK.
- **Operational complexity.** Running a validator is non-trivial (key
  custody, client diversity, monitoring). The dollar uplift (~$400/yr)
  does not justify the ops burden for a single validator; this strategy
  is for users who would run validators anyway (DAOs, exchanges, node-op
  businesses).
- **Pectra (EIP-7251).** Post-Pectra, validators can scale up to 2048 ETH
  effective balance. The 32-ETH-per-pod model survives but compounding
  becomes more efficient at larger sizes.

## Result

Status: **structural / mechanics-only PoC.** Pod creation + ownership round-
trip execute end-to-end on the fork; the proof + delegation + AVS opt-in
flow is documented but requires live beacon-chain state.

PnL (1y, 32 ETH per validator ≈ $96k):
- Base (EIGEN @ $3.50/pt, single AVS): ~+$45k.
- Bear (no EIGEN/AVS value): ~+$3.8k (CL only).
- Delta vs Lido: ~+$400/yr (10x at higher AVS yield).
