# B11-04: asBNB peg flash arbitrage (Astherus mint × PCS v3)

## Mechanism
asBNB has two prices:

1. **Internal rate** — `asBNB.convertToAssets(1e18)` driven by the Astherus
   StakeManager. This is the canonical mint/redeem rate and drifts up only
   (validator yield).
2. **Pool rate** — PCS v3 asBNB/WBNB pool spot. This is set by trades and
   can dislocate either way because Astherus' redemption queue is
   asynchronous, so arbitrage can only close the *premium* side atomically.

When pool implies **asBNB > internal rate** (secondary premium):
- flash WBNB from the same pool's sibling fee tier
- unwrap → mint asBNB via StakeManager (cheap)
- sell asBNB into the pool that has the premium
- repay flash
- profit = pool premium − flash fee − swap fee

This is the asBNB analogue of B02-01 (slisBNB peg arb). The discount side
is *not* atomically arbable because redemption is queued (7-15 day unbond),
so this PoC only implements the premium-side flash trade.

## Why it composes
- Astherus StakeManager is the *cheap mint side* — analogous to Lido /
  Lista, the protocol always honors the internal rate for new mints. A
  premium in the pool means anyone with BNB can mint at internal and
  immediately sell.
- PCS v3's split-pool single-pair structure (multiple fee tiers on the same
  pair) gives us a sibling pool to flash from while swapping in the other
  one — no reentrance.
- Capital efficiency: only the flash fee (5-25 bp depending on tier) is at
  risk, vs holding inventory.

## Preconditions
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER` live at the pinned block.
- PCS v3 asBNB/WBNB pool exists at the 0.25 % fee tier (flash venue) and
  the 0.01 % fee tier (swap venue), with adequate depth.
- Pool implies asBNB ≥ internal rate × (1 + flash_fee + swap_fee + ε).
  Below threshold the strategy reverts without consuming capital.

## Strategy steps
1. Resolve PCS v3 asBNB/WBNB 0.25 % flash pool. Fall back to
   `IPancakeV3Factory.getPool` if hard-coded address has no code.
2. Pre-fund `REPAY_BUFFER = 505 WBNB` to cover flash + fee deterministically.
3. `flashPool.flash(self, FLASH_NOTIONAL=500 WBNB, 0, data)`.
4. In the flash callback:
   - `WBNB.withdraw(500)` → 500 native BNB.
   - `ASTHERUS_STAKE_MANAGER.deposit{value: 500}()` → ~487.8 asBNB at
     internal rate 1.025.
   - PCS v3 0.01 % tier swap asBNB → WBNB at the premium price → ~509.8
     WBNB out.
   - Repay flashPool: `500 + 1.25 (0.25 % fee) = 501.25 WBNB`.
5. Net delta on the test wallet: **+~8.5 WBNB on REPAY_BUFFER 505**, i.e.
   ~1.7 % atomic return on capital.

## PnL math
At pinned block 45,500,000, assumed dislocation:
- Pool spot: 1.045 BNB / asBNB
- Internal rate: 1.025 BNB / asBNB
- Gross spread: 2.00 %
- Flash fee (0.25 %): 1.25 BNB
- Swap fee (0.01 %): 0.05 BNB
- Net: ~1.70 % × 500 BNB notional ≈ **+8.5 BNB**
- At $600/BNB → **~+$5,100 atomic** for a single tx.

Gas: ~300 k for flash + mint + swap + repay → ~$0.18 at 1 gwei. Negligible.

### Why the trade is not always available
The pool premium decays once a single executor takes the trade. In practice
the strategy is **opportunistic** — keep a hot wallet pre-funded with the
505 WBNB buffer and watch for dislocations in the 50-200 bp range. At
< 30 bp the trade is unprofitable (fees > spread).

## Block pinned
**45,500,000** — TODO re-pin to a block where the dislocation is materially
observable. PoC is offline-first; the offline path models the exact 200 bp
dislocation above.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.asBNB` — **TODO verify** (both flagged
  in `BSC.sol`).
- `PCS_V3_POOL_ASBNB_WBNB_2500` — placeholder; PoC falls back to
  `PCS_V3_FACTORY.getPool` to resolve at runtime.
- `BSC.PCS_V3_FACTORY`, `BSC.PCS_V3_ROUTER`, `BSC.WBNB` — verified.

## Risks
- **Pool depth**: thin PCS v3 asBNB/WBNB liquidity → moving 500 BNB through
  the swap leg can self-correct most of the spread. Mitigation: size the
  flash to ≤ 5 % of `pool.liquidity()` (not yet enforced in the PoC).
- **Sibling-pool absence**: if only one fee tier exists for asBNB/WBNB,
  flash + swap on the same pool deadlocks (reentrancy). Mitigation: the PoC
  uses two different fee tiers (0.25 % flash, 0.01 % swap).
- **StakeManager pause**: if Astherus pauses `deposit()` mid-flash, the
  whole tx reverts and we lose only the gas. Acceptable.
- **TODO-verify addresses**: PoC gates every external call with
  try/catch + `_hasCode`, so a bad address yields the offline simulation
  rather than a dirty revert.
- **Frontrunning**: BSC has private mempool services (48 Club, Blockrazor)
  that mostly absorb this; for safety, route the live trade through one of
  them.

## Result
Status: **theoretical** (offline-first; both asBNB and ASTHERUS_STAKE_MANAGER
addresses still `TODO verify`). Expected PnL per executed instance: **~+8.5
BNB ≈ +$5,100** atomic profit at the modelled 200 bp dislocation. With the
spread below 30 bp the strategy is a no-op (the tx reverts without consuming
capital beyond gas).
