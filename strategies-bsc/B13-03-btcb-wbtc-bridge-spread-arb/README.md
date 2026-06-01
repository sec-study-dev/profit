# B13-03: BTCB (BSC-native) vs WBTC (bridged) cross-chain spread arb

## Mechanism
On BSC two ostensibly-fungible Bitcoin wrappers coexist:

1. **BTCB (`0x7130...d9c`)** — Binance-Peg BTC. The dominant BTC liquidity
   on BSC; PCS v2, PCS v3, Venus, and Wombat all denominate against BTCB.
2. **WBTC (BitGo, bridged via LayerZero / Wormhole)** — *not* the same
   contract as Ethereum's WBTC. On BSC it sits in a much shallower PCS v3
   pool and is mostly used by cross-chain users moving WBTC from
   Ethereum / Polygon to BSC for Pendle / Avalon flows.

Because BTCB is fully redeemable 1:1 BTC through Binance's centralised
desk while WBTC is redeemable 1:1 BTC through BitGo's centralised desk
(different paths, different SLAs), the two trade at a small but
non-trivial spread on BSC. Typical states:

- **Default (60% of time)**: WBTC quotes 10-30 bp **discount** to BTCB
  on PCS v3 because most flow goes BTCB-first.
- **Bridge-inflow spikes** (Pendle WBTC pool TGE, Avalon WBTC market
  launch): WBTC quotes 20-60 bp **premium** to BTCB for hours.
- **CEX deposit windows**: when Binance opens a WBTC deposit promo, WBTC
  on BSC briefly trades flat or premium as users move it on-chain.

The arb (default case, WBTC discounted vs BTCB):

1. PCS v3 `flash(BTCB, N)` from the BTCB/USDT 0.05% pool (deepest BTCB
   pool).
2. In the callback: `exactInputSingle(BTCB -> USDT)` already happened
   implicitly via the flash setup; instead, the cleaner flow is to swap
   in the *opposite* direction. Concretely: flash WBTC from the
   BTCB/WBTC pool itself, swap WBTC -> BTCB on a sibling tier, hold the
   excess BTCB as PnL.
3. Repay flash WBTC from a pre-funded WBTC buffer.

Because BTCB and WBTC are **both ERC-20s already on BSC**, there is no
LayerZero send-leg involved in the arb itself — the bridge spread
manifests purely as a PCS v3 pool dislocation. The "cross-chain" part is
the *source* of the spread (different bridge SLAs), not the execution
path. This makes the strategy **atomic on BSC**.

## Why it composes
- **BTCB liquidity moat**: every BSC DeFi protocol routes BTC through
  BTCB, so any short-lived WBTC excess immediately becomes a one-pool
  arb against BTCB.
- **No off-chain bridge dependency**: unlike B13-01 (OFT-USDT0 burn) and
  B13-04 (USDe roundtrip), this PoC closes the loop on BSC. The "bridge
  spread" is captured but not the bridge itself.
- **Oracle override**: BTCB and WBTC both price at ~$65,000 / BTC; the
  PoC keeps both pegged to BTC and lets the *swap output* drive the PnL.

## Preconditions
- A PCS v3 pool exists for BTCB/WBTC. TODO: confirm address on BscScan;
  the PoC falls back to `getPool(BTCB, WBTC, 500)` then `(BTCB, WBTC, 100)`.
- WBTC on BSC: `0x1aaC...AF8` (BSC native WBTC bridged via LayerZero).
  TODO: this address is **not** in `BSC.sol` — the PoC hardcodes it and
  notes that B13 cannot edit `BSC.sol` (Wave 2 hard constraint).
- BTCB has 18 decimals on BSC; WBTC on BSC has 8 decimals (matches
  Ethereum WBTC). The PoC handles the decimal asymmetry.

## PnL math
Let `D` = WBTC discount vs BTCB in bp. Flash notional `N` WBTC (8 dec).
- WBTC out from swap leg (BTCB -> WBTC sibling pool): `N * (1 + D/10000)`
- Flash fee: `N * fee_tier / 10^6` (5 bp = 0.0005 BTC per BTC borrowed)
- Net BTCB-equivalent gain: `N * (D/10000 - fee_tier/1e6)`
- For `D = 25 bp`, `N = 10 BTC` (= 10e8 WBTC base units):
  gross = 10 * 0.0025 = 0.025 BTC ≈ **$1,625 @ $65,000/BTC**
- For `D = 60 bp`, `N = 10 BTC`: gross ≈ 0.060 BTC ≈ **$3,900**.

## Block pinned
- `FORK_BLOCK = 46_800_000` — placeholder. Re-pin to a window where the
  PCS v3 BTCB/WBTC slot0 implies a > 20 bp spread. TODO: scan PCS
  analytics for BTCB/WBTC 500bp pool.

## Risks
- **WBTC pool depth on BSC is thin**: 10 BTC notional may move the pool
  > 50 bp on its own. PoC caps N at 5 BTC and notes that production
  sizing must be slot0-driven.
- **WBTC contract address on BSC may have multiple deployments**
  (LayerZero, Wormhole, Multichain legacy). The PoC standardises on the
  LayerZero v2 deployment; production must whitelist.
- **Cross-fee tier slippage**: flash on 0.05% tier, swap on 0.01% tier;
  the swap-tier pool may itself be unsynced. PoC includes a slippage
  guard via `amountOutMinimum`.

## Status
- **Atomic on BSC** — flash + swap + repay in one tx.
- Offline-first PoC; emits `pnl_usd=` via BSCStrategyBase.
