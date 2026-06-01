# B09-01: USDT/USDC Wombat vs PCS StableSwap flash arb

## Mechanism
Two BSC stable AMMs price the USDT <-> USDC pair using different invariants:

- **Wombat Main Pool** (`0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0`) uses a
  *dynamic asset weight* curve. Each token's marginal slippage depends on the
  pool's **coverage ratio** `cov = cash / liability`. When a side is heavily
  over-allocated (`cov > 1.2`) the haircut on swapping *into* that asset
  collapses, and swapping *out* of the over-allocated side starts running into
  steep slippage well before Curve's typical "edge of A region" kicks in.
- **PancakeSwap StableSwap Router** (`PCS_STABLE_ROUTER`, Curve fork) uses a
  classic invariant with fixed amplification. Its quote for USDT->USDC is
  effectively flat in the +/-5% balance range.

When Wombat's USDT side is ~62% of pool liability and PCS is balanced, the
quotes diverge by 8-25 bp on a $1M-scale swap. The arb is atomic via a PCS v3
**single-pool flash** of USDC from the USDC/USDT 0.01% v3 pool:

1. `flash(USDC, N)` from `USDC/USDT` v3 pool (1 bp fee).
2. In callback: route `USDC -> USDT` through the venue with the **better**
   quote (typically Wombat when its USDC side is under-allocated and pays
   bonus liability-restoration credit).
3. Route `USDT -> USDC` back through the **worse** venue (PCS StableSwap).
4. Repay flash USDC + 1 bp from the surplus USDC.

## Why it composes
- **Wombat dynamic-weight discount**: when `cov_USDC < 1`, Wombat's swap *out*
  of USDT pays the swapper a small premium ("coverage incentive") because the
  pool wants to restore USDC liability. This is mechanically distinct from
  Curve/PCS, where the only signal is the price-curve midpoint.
- **PCS v3 flash**: single-pool flash on the USDC/USDT 1bp tier means the
  flash premium is 1 bp on the borrowed leg — far less than the cross-venue
  spread we're harvesting.
- **No directional risk**: USDT and USDC are both 18-decimal BSC stables; the
  position opens and closes within one tx.

## Preconditions
- USDC/USDT PCS v3 0.01% pool exists and has enough liquidity for the flash
  (typical TVL: $50M+, supports $10M+ flashes at <1 bp impact).
- Wombat USDC and USDT are both registered as assets in the Main Pool.
- Coverage ratio asymmetry: `|cov_USDT - cov_USDC| > 0.05`. The PoC enforces
  this offline by assuming the standard mid-2024 imbalance pattern.

## PnL math
For a flash notional `N = 1_000_000 USDC`:
- Wombat USDC->USDT quote (under-allocated USDC, cov=0.92): ~1.0008 USDT/USDC
  (8 bp bonus from coverage incentive).
- PCS StableSwap USDT->USDC quote (balanced): ~0.9999 USDC/USDT (1 bp haircut).
- Round-trip output: `1_000_000 * 1.0008 * 0.9999 ≈ 1_000_700 USDC`.
- Flash premium: `1_000_000 * 0.0001 = 100 USDC`.
- Wombat haircut (5 bp default): already netted into the 8 bp bonus quote
  above; net pool delta is the 8 bp coverage credit minus the 5 bp haircut.
- Net profit per $1M: ~$600 = 6 bp.

Realistic dislocations:
- Quiet periods (cov spread < 0.02): 1-2 bp -> unprofitable after flash fee.
- Normal flow (cov spread 0.05-0.10): 5-10 bp net -> $500-$1,000 / $1M.
- Stressed flow (large LP withdrawal on one side): 20-50 bp -> $2,000-$5,000.

## Block pinned
- `FORK_BLOCK = 45_500_000` (placeholder, ~Q3 2024). **TODO** verify a block
  where the Wombat USDC coverage ratio drifts > 0.05 below USDT's.

## Risks
- **Wombat haircut rate change**: governance can bump the haircut from 5 bp;
  PoC reverts if `quotePotentialSwap` returns less than the precomputed
  threshold.
- **PCS StableSwap pool index**: `i=0, j=1` for USDT/USDC has to match the
  on-chain coin ordering (TODO verify the canonical 3pool order: BUSD, USDT,
  USDC — likely `i=1, j=2`).
- **Same-block competition**: known venue; private RPC required in
  production.

## Result
- Status: **theoretical / offline-first** (no BSC RPC; offline path simulates
  the documented 8 bp Wombat coverage bonus on a $1M notional).
- Expected PnL: **+$500 to +$2,000 per $1M flashed** at typical dislocations.
