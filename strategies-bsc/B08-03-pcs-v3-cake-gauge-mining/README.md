# B08-03: PCS v3 USDe/USDT concentrated LP → MasterChef v3 → CAKE farm

## Mechanism
The PancakeSwap analogue of B08-01, but on PCS v3 (Uniswap v3 fork) where
liquidity is concentrated in a tick range and CAKE emissions are dripped
by `MasterChefV3` (the gauge equivalent on PCS). Stablecoin pair so
emission yield is the dominant term and IL is trivially small.

Three primitives:

1. **PCS v3 USDe/USDT 0.01% pool** — both legs are dollar-pegged. The
   0.01% (1 bp) tier exists on BSC for stable–stable pairs. We mint a
   concentrated position with a tight ±5 bp range around current tick to
   maximise liquidity efficiency.
2. **PancakeSwap MasterChefV3** — the v3-aware staking contract. Instead
   of taking an ERC-20 LP token, it takes the Uniswap-v3-style NFT
   position from `NonfungiblePositionManager` (`safeTransferFrom`). Each
   epoch CAKE emission is allocated by the gauge controller; per-pool
   share comes from the `cakePoolInfo` table and decays over time.
3. **CAKE → USDT off-ramp** — harvested CAKE is sold on PCS v2 (canonical
   CAKE/WBNB + WBNB/USDT route) and credited back to USDT.

## Why it composes
- USDe and USDT trade within ±5 bp 99% of the time, so a tight v3 range
  earns full fees and ~0 IL.
- PCS gauge has been deliberately boosting USDe/USDT pools as part of the
  Ethena partnership, so CAKE allocation is rich; effective APR on the
  base liquidity is in the 15–40 % range during the boost period.
- The Position NFT is itself collateral in B11/B14 stacks — so the same
  position can later be wrapped into a downstream leverage strategy
  without unwinding (out of scope here).

## Preconditions
- USDe deployed on BSC at pinned block (confirmed since mid-2024).
- PCS v3 USDe/USDT pool exists with non-zero liquidity at the 0.01 % tier.
- MasterChefV3 has the pool registered (`pids` mapping non-zero) and CAKE
  allocation per block > 0.
- Sufficient WBNB liquidity on PCS v2 for the CAKE → USDT roundtrip.

## Strategy steps
1. Seed wallet with 1 000 000 USDT (≈$1M deploy size, representative
   farm-quality position).
2. Swap 500 000 USDT → USDe on the PCS v3 0.01 % pool (the pool is its
   own oracle, so we use a `swapExactInputSingle` with a 5 bp limit).
3. Mint NFT position via `NonfungiblePositionManager.mint` with range
   `[tickCurrent - 5, tickCurrent + 5]` (5 ticks ≈ ±5 bp). The PoC sizes
   both legs to the active ratio.
4. Approve + `safeTransferFrom` NFT to `MasterChefV3`.
5. Warp `HOLD_DAYS = 7` and accrue:
   - LP fees: modeled at 0.01 % × weekly volume share.
   - CAKE emission: modeled at assumed boost APR.
6. Call `MasterChefV3.harvest(tokenId, to)` → CAKE lands in wallet.
7. Swap CAKE → WBNB → USDT on PCS v2.
8. Withdraw NFT (`MasterChefV3.withdraw(tokenId, to)`) and decrease
   liquidity to return USDe + USDT to wallet.
9. Print PnL.

## Numbers (assumed $600/BNB, $2.40/CAKE)
- Notional: $1 000 000 deployed.
- Assumed CAKE gauge APR for boosted USDe/USDT pool: **22 %**.
- 7-day window: 22 % × 7/365 = 0.422 % of notional in CAKE = **$4 220**.
- LP fees at 0.01 % tier — pool weekly volume assumed $50 M, our share
  10 % (typical for a tight $1 M deposit on a $10 M TVL pool):
  $50 M × 0.01 % × 10 % = **$500 / week**.
- IL over the epoch (USDe drifts ±2 bp): < $50.
- CAKE → USDT slippage at $4 220 batch: 0.4 % = $17.
- Gas: ~8 calls × 250k @ 1 gwei × $600/BNB ≈ $1.20.

Expected net: **~$4 700 / week ≈ 24 % APR.** Marginal but stable; the
strategy is mostly a beta to CAKE emission schedule.

## Risks not modelled
- USDe depeg (worst observed: -2 % during March 2024 — would push the
  position out of range and stop fee/emission accrual).
- CAKE allocation cuts: gauge controller can drop the pool's pid_allocPoint
  with one governance vote. Mitigation: weekly re-evaluation.
- Pool can briefly become single-sided post-swap; the PoC reverts if it
  detects the active tick has moved outside our range during the mint.

## TODO
- Verify on bscscan: PCS `NonfungiblePositionManager` and `MasterChefV3`
  contract addresses for the pinned block (BSC.sol does not list them so
  they live in this PoC as `LOCAL_` constants).
- Confirm USDe/USDT pool address + fee tier; PoC currently looks it up
  via `PCS_V3_FACTORY.getPool`.
- Live `pid` lookup on MasterChefV3 (some forks use `v3PoolAddressPid`,
  some use a separate registry).
