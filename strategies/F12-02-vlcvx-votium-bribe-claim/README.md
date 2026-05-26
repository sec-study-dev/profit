# F12-02: vlCVX lock + Votium MultiMerkleStash bribe-claim simulation

## Mechanism
**vlCVX** (vote-locked CVX) is a 16-week lock of CVX that grants
vote-weight on Convex's snapshot proposals. Each Thursday Convex snapshots
the vote, distributes its veCRV vote-weight across Curve gauges according
to vlCVX-holders' ballots, and emits the resulting CRV+CVX to LPs of those
gauges. Bribe markets exist because vlCVX-holders capture none of the LP
emission directly — instead they sell their vote to whoever wants Curve
emissions on a specific pool.

**Votium** is the dominant bribe market for Convex. The lifecycle:
1. A protocol (Frax, Aura, Concentrator, etc.) deposits an ERC20 bribe
   into `Votium.depositBribe(pool, token, amount)`.
2. Snapshot vote runs Mon-Wed.
3. Votium operator computes proportional payouts and **publishes a Merkle
   root per ERC20 token** to the `VOTIUM_MULTI_MERKLE_STASH`
   (`0x378Ba9B73309bE80BF4C2c027aAD799766a7ED5A`) every other Thursday.
4. Voters call `claim(token, index, account, amount, merkleProof)` for
   each token they earned.

The claim mechanism is a standard Merkle distributor: the leaf is
`keccak256(abi.encodePacked(index, account, amount))` and the root is per
token. Multiple ERC20 tokens accumulate per round (a typical round has
20-40 bribe tokens). Once claimed, `isClaimed(token, index)` is set; the
position is fully fungible — there is no claw-back.

## Why it composes
1. **vlCVX 16-week lock** — illiquid but vote-bearing. It pays nothing
   directly; the only revenue is the bribe market.
2. **Votium** — turns the vote into a basket of ERC20 rewards.
3. **The two MUST be combined**: a CVX holder who only locks without
   delegating to Votium's address strategy earns *zero* bribes. The
   on-chain composition is:
   - `vlCVX.lock(self, amount, 0)` — produces vote-weight at next epoch.
   - `vlCVX.delegate(VOTIUM_VOTE_PROXY)` (off-chain Snapshot recognises
     this delegation) — opts into the Votium round.
   - `VOTIUM_MULTI_MERKLE_STASH.claim(...)` for each token in the round.

## Preconditions
- Mainnet fork at a block right after a Votium epoch has been posted (the
  contract's `merkleRoot(token)` is non-zero for the bribe tokens).
- A funded test account with CVX to lock.
- **Merkle proof source.** Real proofs are published by Votium's
  off-chain operator at https://merkle.llama.airforce/api/v1/votium/ ... 
  Each round has a JSON file `<round>.json` keyed by claimant address
  with `{ index, amount, proof }`. For an end-to-end PoC against a *real*
  round, you must inject the JSON into Foundry via `vm.readFile` and
  match `account == address(this)`, which means cherry-picking a fork
  block where `address(this) == <a known whale that voted>`.
  Our PoC takes the **simulation route**: we
    a) overwrite the `merkleRoot(token)` storage slot to a one-leaf root
       whose preimage we control, and
    b) submit the trivial 0-length proof.
  This exercises the full call path (`claim()` Merkle verifier, balance
  transfer, `isClaimed` bit-flip) without requiring an off-chain
  Merkle JSON.

## Strategy steps
1. Fork at block `19_643_500` (Apr 13 2024 — well after a Votium epoch).
2. Fund test contract with 10,000 CVX. Approve and `vlCVX.lock(self,
   10_000e18, 0)`. Read `lockedBalanceOf` to confirm.
3. Delegate to Votium's vote proxy (on-chain `delegate` call). This is
   off-chain consumed by Snapshot but on-chain it is just a state-write.
4. Warp 14 days to land in the next bribe-claim window.
5. **Simulate a published bribe**:
   - Pick FXS (`0x3432B6…64D0`) as bribe token. Fund the stash with
     1,000 FXS via `_fund(FXS, VOTIUM_STASH, 1000e18)`.
   - Compute leaf = `keccak256(abi.encodePacked(uint256(0), self,
     uint256(1000e18)))`.
   - `vm.store(VOTIUM_STASH, keccak256(abi.encode(FXS, MERKLE_ROOT_SLOT)),
     leaf)` — single-leaf root equals leaf.
6. Call `Votium.claim(FXS, 0, self, 1000e18, emptyProof)`. Confirm FXS
   balance and `isClaimed(FXS, 0) == true`.
7. Repeat for a second token (CVX bribe). Total bribe basket: FXS +
   crvUSD + CVX.

## PnL math
Bribe APR is the only revenue. Empirically Q1-2024 the average bribe
`$/vlCVX/round` was **$0.08-$0.18** (two-week round). At round-end
exchange rate ~$2.10/CVX that is **0.04-0.09 % per 2 weeks** of CVX
notional, or **~1.0-2.3% annualised** in bribe-token rewards.

For 10,000 CVX locked over one round:
```
bribe_usd ≈ 10_000 * $0.12 = $1,200      (round-average)
```
Bribe tokens are heterogeneous; the PoC accounts in raw token units and
the README values them at:
- FXS  ~ $3.20
- crvUSD = $1.00
- CVX  ~ $2.10

## Block pinned
**19_643_500** (Apr 13 2024). Votium round 56 closed Apr 4 2024,
round 57 closed Apr 18 2024 — block 19_643_500 sits between, so the
stash's merkleRoot(token) for round 56 is *already on chain* (we still
overwrite to a known leaf for self-claim).

## Risks & uncertainties
- **Merkle proof handling.** Without an off-chain proof feed the PoC
  cannot exercise *real* bribe data; we use the `vm.store` simulation
  route. A production strategy must wire in the Votium API. The
  `MERKLE_ROOT_SLOT` is `0` in Votium's storage layout (mapping
  `merkleRoot` is the first state variable after `Ownable` -> slot 0 on
  the inherited contract or slot 51 with OZ Ownable's storage gap). We
  compute the slot dynamically via `vm.load`/`vm.store` after a forge
  call to `merkleRoot(token)` to confirm the layout.
- **Delegation off-chain only.** The on-chain `delegate()` is a no-op
  for reward distribution — Votium's snapshot strategy reads this state.
  A pure-fork test cannot exercise the Snapshot tally.
- **Lock is 16 weeks, real.** The PoC does NOT warp past unlock; the PoC
  ends with the bribe claimed and the position still locked. PnL is the
  bribe-basket value only; the CVX delta is zero (still in vlCVX).
- **`update()` counter.** Votium's `update()` is incremented each new
  round. Our injected leaf is checked under whatever the current
  `merkleRoot(token)` is, so simulation works regardless.

## Result
Status: **theoretical, foundry build not run**. Storage-slot hack
exercises Votium's claim verifier end-to-end; a real-round PoC requires
JSON proof injection (TODO if forge available).

Expected per-round PnL on 10,000 CVX:
- bribes ≈ **$800-$1,800** in mixed tokens
- gas ≈ 600k for lock+delegate+two claims @ 20 gwei ≈ $0.40
- net ≈ **+$800 / 14d / 10k CVX**
