# B09-05: Wombat USDe sidecar pool dynamic-weight skew arb

## Mechanism
Wombat operates a dedicated **USDe/USDT sidecar pool** (separate from the
stables Main Pool) so that USDe's bridged-OFT supply behavior does not
contaminate the FDUSD/USDC/USDT Main Pool.

USDe lands on BSC via Ethena's **LayerZero OFT** mint — i.e. supply is
created on BSC when a user bridges from mainnet, and burned when they bridge
back. Cross-chain LP rebalancers (Karak/Symbiotic/Aerodrome side) tend to mint
into the BSC OFT and then *deposit one-sided into Wombat* to capture the LP
fees on the BSC-side flows. The result: `cov_USDe` on the Wombat sidecar
routinely drifts to 1.25-1.40 while `cov_USDT` sits near 1.0.

When `cov_USDe > 1.3`, Wombat's dynamic-asset-weight formula pays the *next
USDe seller* a non-trivial coverage-restoration bonus (the pool wants USDe
out, USDT in). PCS StableSwap's USDe/USDT pool uses a fixed-A Curve invariant
and pays only the flat ~0 bp curve price near balance. The two diverge by
8-20 bp on a $750k notional.

The arb is non-flash:

1. Treasury holds USDe (modelled via `_fund`).
2. `Wombat.swap(USDe -> USDT)` on the sidecar — harvests the over-quote.
3. `PCS Stable.exchange(USDT -> USDe)` — restores the inventory at the flat
   reference curve.
4. Realize the spread (`legB - notional`).

No flash because the position opens and closes on the same token. The funder
is effectively a market-maker timing the cov drift, not a flash-arber.

## Why it composes
- **Wombat dynamic-asset-weight on a non-CEX stable**: USDe's OFT mint flow
  is asymmetric (one-sided BSC deposits dominate) which keeps the pool
  consistently skewed in one direction. This is mechanically different from
  USDT/USDC where flows are bidirectional and revert to mean.
- **PCS Stable as a flat counterparty**: the USDe/USDT PCS Stable pool has
  much less directional flow and quotes near 0 bp, making it a clean exit.
- **No directional risk**: positions opens/closes in USDe, no exposure to
  USDe peg moves.

## Mechanism count
**2-mechanism**: (1) Wombat dynamic-weight pool, (2) PCS StableSwap.

## Preconditions
- Wombat USDe sidecar pool exists. **TODO verify** the address on BscScan;
  PoC uses a placeholder and falls back to the Main Pool if extcodesize == 0
  (Main Pool likely does not list USDe).
- PCS Stable has a USDe/USDT pool listed. **TODO verify** indices.
- At the chosen block: `cov_USDe > 1.3` AND `cov_USDT ~ 1.0`.

## PnL math
At `cov_USDe = 1.32` (post-OFT-mint state):
- Wombat USDe->USDT quote: ~14 bp gross bonus, -5 bp Wombat haircut -> +9 bp
  net on the seller.
- PCS Stable USDT->USDe: -1 bp flat.
- Net per $750k: `750_000 * (1.0009 * 0.9999 - 1) = ~$600`.

Realistic dislocations:
- Quiet OFT week (`cov_USDe < 1.1`): 1-2 bp -> unprofitable after gas.
- Normal OFT pump (`cov_USDe 1.2-1.3`): 5-9 bp -> $375-$675.
- Cross-chain rebalancer event (`cov_USDe > 1.4`): 15-25 bp -> $1,125-$1,875.

## Block pinned
- `FORK_BLOCK = 46_100_000` (placeholder, ~Q4 2024). **TODO** verify a block
  where the Wombat USDe sidecar has cov_USDe > 1.3.

## Risks
- **Pool address unverified**: PoC uses a placeholder; on-fork branch falls
  back to Main Pool, where USDe likely is not listed and the call reverts.
- **OFT mint timing**: arb opportunity is correlated with bridging events; a
  passive funder may sit idle for days between dislocations.
- **PCS Stable depth**: the USDe/USDT PCS pool may be thinner than the
  notional; the second leg can suffer >1 bp slippage.
- **USDe depeg tail**: USDe has its own peg risk; while the arb is in-and-out
  in one tx, a stale-block fork can mis-price the spread direction.

## Result
- Status: **theoretical / offline-first** (no BSC RPC; offline path uses the
  14 bp gross / 9 bp net assumption documented in the strategy comment).
- Expected PnL: **+$200 to +$2,000 per $750k notional** at typical
  post-bridging dislocations.

## TODO
- Verify Wombat USDe sidecar pool address on BscScan.
- Verify the PCS Stable USDe/USDT pool address and `i,j` indices.
- Pin a real block with cov_USDe > 1.3.
