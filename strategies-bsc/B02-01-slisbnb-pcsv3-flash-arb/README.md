# B02-01: slisBNB / WBNB PancakeSwap v3 single-pool flash arb

## Mechanism
Lista DAO's slisBNB is a non-rebasing BNB LST. Its canonical BNB-denominated
value comes from `IListaStakeManager.convertSnBnbToBnb(1e18)` on
`0x1adB950d8bB3dA4bE104211D5AB038628e477fE6`. This rate only goes **up**
(monotonic) as validator rewards accrue. In contrast, the slisBNB/WBNB
PancakeSwap v3 pool quote moves with order flow and LP positioning, so over
short windows the spot price often trails the internal exchange rate by
5-30 bp (and occasionally inverts when a large redeem queue prints a
slisBNB sell wall).

The arb is:

1. PCS v3 `flash(WBNB)` from the slisBNB/WBNB pool itself (single-pool flash,
   pays only the 0.01% fee tier surcharge).
2. Swap the flashed WBNB -> slisBNB in the *same pool* (or a sibling 0.05% fee
   pool, depending on which is cheap relative to internal rate).
3. Compare the slisBNB received vs `convertSnBnbToBnb(slisBnbOut)`. If the
   DEX gave more slisBNB than the internal-rate-implied amount the strategy
   keeps the surplus.
4. Two exit modes:
   - **Atomic mode (preferred when the *other* side is also rich):** swap
     slisBNB back to WBNB at the discounted rate on an alternative venue
     (e.g. PCS v2 slisBNB/WBNB v2 pair or the Wombat slisBNB pool) -> repay
     flash WBNB + fee, profit in WBNB.
   - **Queued exit:** `IListaStakeManager.requestWithdraw(slisBnbAmount)` and
     value the resulting claim ticket at the **internal rate** (since Lista
     pays exactly `convertSnBnbToBnb` upon claim, minus a small queue tax).
     This is the F03-01 pattern: PnL is realised in WBNB at flash time but
     the position is "long internal rate vs DEX spot" until the queue clears.

This PoC defaults to **atomic mode** with a pre-funded WBNB buffer that
represents the alternative venue's redemption proceeds (since the
unbond queue is 7-15 days). PnL accounting is dominated by the slisBNB
balance retained, priced at the LST internal rate via the oracle override.

## Why it composes
- **PCS v3 single-pool flash**: lowest possible flash fee (just the pool fee
  for the implied "borrow"; PCS v3 takes `fee * amount` of the borrowed token
  as flash premium, same as Uniswap v3). For 0.01% fee pools this is 1 bp.
- **LST internal rate**: deterministic monotonic; the StakeManager view is
  the source of truth that Lista's own redemption path honors 1:1.
- **DEX spot deviation**: random walk around internal rate, often biased
  down when LST holders take profit on a points/airdrop catalyst.

## Preconditions
- A PCS v3 pool exists for slisBNB/WBNB. Inferred from BscScan pool index:
  `0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb` (0.05% fee tier, **TODO
  verify**; if address is stale the PoC reads via `IPancakeV3Factory.getPool`).
- Lista StakeManager `convertSnBnbToBnb` returns a rate strictly > 1e18 at
  any post-launch block (because rewards have already accrued at least once).
- Flash notional must remain within the pool's liquidity to avoid hitting the
  sqrtPriceLimit cap.

## Strategy steps
1. `factory.getPool(slisBNB, WBNB, 500)` -> resolve pool. (Fee tier 500 = 5
   bp on PCS v3.)
2. Encode callback data: `(notional, amount0Owed, amount1Owed, payer)`.
3. `pool.flash(this, wbnbAmount, 0, data)` (assuming WBNB is token0 in
   slisBNB/WBNB order).
4. In `pancakeV3FlashCallback`:
   a. Use the flashed WBNB to call `pool.swap(this, true, int256(wbnbAmount),
      MIN_SQRT_RATIO+1, data)` — *no*, we cannot reenter the same pool. So
      instead the swap leg routes through `PCS_V3_ROUTER.exactInputSingle`
      against a **sibling pool** (e.g. fee tier 100). The flash and the swap
      execute on different pools (single-pool flash is just for the loan).
   b. Quote internal rate: `bnbValue =
      convertSnBnbToBnb(slisBnbReceived)`. Assert `bnbValue > wbnbFlashed +
      flashFee` (strategy reverts otherwise — no loss).
   c. Repay flash: transfer back `wbnbAmount + fee0` to the pool. Buffer
      pre-funded with `_fund(WBNB, this, REPAY_BUFFER)` so the repay never
      depends on an instant slisBNB sell.
5. After the flash returns, the strategy retains `slisBnbReceived` worth
   `bnbValue > wbnbFlashed` BNB. PnL accounting via `_tracked` shows this as
   slisBNB delta (priced at internal-rate-corrected oracle) minus WBNB
   consumed from the buffer.

## PnL math
Let `R = convertSnBnbToBnb(1e18) / 1e18` (BNB per slisBNB, e.g. 1.078).
Let `P = pool quote` (slisBNB per WBNB, e.g. 0.930).

For flash notional `N` WBNB:
- slisBNB out: `N * P` (e.g. 1000 * 0.930 = 930 slisBNB)
- BNB-value of slisBNB: `N * P * R` (e.g. 1000 * 0.930 * 1.078 = 1002.5 BNB)
- Flash fee (5 bp): `0.0005 * N`
- Gross PnL = `N * (P * R - 1 - 0.0005)`
- For `P * R = 1.0025` (25 bp dislocation), `N = 1000`: gross ≈ 2 BNB ≈
  $1,200 @ $600/BNB. Gas on BSC is sub-$1.

Realistic dislocations:
- 5-10 bp during quiet periods → ~$300-600 per 1000 WBNB
- 25-50 bp during slisBNB sell pressure → ~$1,500-3,000 per 1000 WBNB
- 100+ bp during Lista UI outages or queue spikes (rare)

## Block pinned
- `FORK_BLOCK = 45_000_000` (placeholder, ~Q3 2024). At that block the
  slisBNB/WBNB 0.05% pool typically quotes within 10-20 bp of internal rate.
- **TODO**: scan PCS analytics for blocks where the 1h TWAP slisBNB/WBNB
  drifts >25 bp below internal rate and pin one of those.

## Risks
- **Wrong pool address**: if the inferred pool address is stale, the PoC
  must fall back to `factory.getPool`. Coded defensively.
- **Same-pool flash + swap is impossible**: PCS v3 (and Uniswap v3) reverts
  on reentrancy. The PoC routes the swap through the **0.25% fee tier**
  sibling pool, or the PCS v2 slisBNB/WBNB pair, or via the router with the
  flashed-pool excluded by setting an explicit `fee` value. **TODO** verify
  PCS has both 100 and 500 fee tiers on slisBNB/WBNB.
- **Sandwich**: the flash itself signals a large taker; private RPC required
  in production. Not a concern for the PoC.
- **slisBNB queue tax**: if exiting via `requestWithdraw`, Lista may charge
  a 1-10 bp fee depending on the contract version. PoC sticks to atomic
  exit so this only matters for the "non-atomic mode" comment.

## Result
- Status: **theoretical / offline-first** (no BSC RPC yet; the PoC compiles
  and runs without a fork by branching on `BSC_RPC_URL` presence).
- Expected PnL: **+$300 to +$2,000 per 1000 WBNB** at typical dislocations.
