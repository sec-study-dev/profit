# B13-01: Bridged USDT (LayerZero OFT) vs BSC native USDT discount flash

## Mechanism
On BSC there are two practically distinct USDT supplies that the market often
treats as 1:1 but occasionally aren't:

1. **BSC-Peg USDT (`0x55d3...7955`)** — the canonical Binance-bridged USDT
   (18 decimals) that PancakeSwap, Venus, Wombat etc. all quote against.
2. **LayerZero OFT USDT0** — Tether's native OFT version, bridged from
   Ethereum via the OFT Adapter (`USDT_OFT_ADAPTER`, TODO verify address).
   The OFT settles atomically (mint on dest = burn on src), but for users to
   *convert* OFT-USDT0 to the BSC-Peg USDT they have to swap on PancakeSwap
   v3 against a relatively shallow OFT/Peg pair.

When ETH→BSC bridge demand spikes (e.g. a points campaign on Lista or a new
Pendle pool), OFT-USDT0 supply on BSC grows faster than the
OFT/Peg PCS pool can rebalance, and the OFT trades at **20-80 bp discount**
to the Peg USDT for ~5-30 minutes. The reverse also happens during
BSC→ETH outflows.

The arb is:

1. PCS v3 `flash(USDT_peg, N)` from the deepest USDT-Peg pool (e.g.
   USDT/USDC 0.01% tier or USDT/WBNB 0.05%).
2. In the callback: `exactInputSingle(Peg → OFT)` against the OFT/Peg pool
   while it's discounted. Receive `N * (1 + spread)` OFT-USDT0.
3. Call `IOFTAdapter.send({dstEid: 30101 /* ETH */, to: address(this),
   amountLD: oftAmount, ...})` — this **atomically** burns OFT on BSC and
   queues a delivery on Ethereum. The burn is final at this block, but the
   ETH-side delivery only finalises ~1-3 minutes later when the LayerZero
   executor runs.
4. Repay the PCS v3 flash from a pre-funded Peg-USDT buffer (representing
   the eventual Ethereum-side redemption proceeds re-bridged back).

Because the LayerZero settlement is *not* same-block, this strategy is
**positional, not atomic**: the burn locks in the spread but the cash leg
on Ethereum (and any onward swap back to BSC-Peg) takes minutes. PnL is
booked at flash time against the OFT exchange rate honored 1:1 by the
adapter.

## Why it composes
- **PCS v3 single-pool flash on the Peg side** gives ≤ 1 bp loan cost.
- **LayerZero OFT V2 atomic burn** means the BSC-side balance change is
  deterministic — no front-running risk on the burn itself.
- **Cross-chain delivery delay** is the *only* timing risk; the spread is
  captured when the burn lands, not when the ETH-side credit lands.

## Preconditions
- `BSC.USDT_OFT_ADAPTER` is a deployed OFT v2 adapter exposing `send` and
  `quoteSend` (TODO verify mainnet address; currently `address(0)` in
  `BSC.sol`).
- A PCS v3 pool exists for OFT-USDT0 / Peg-USDT (TODO verify; the PoC
  assumes the 0.01% fee tier and falls back to the 0.05% tier).
- LayerZero peer for Ethereum endpoint id `30101` is configured on the
  adapter.

## PnL math
Let `D` = OFT discount vs Peg (bp). Flash notional `N` Peg-USDT.
- OFT received from swap: `N * (1 + D/10000)`
- OFT burned via `send`: same; ETH-side delivery: `N * (1 + D/10000)` USDT
  on Ethereum, valued at 1:1 (Tether redeems OFT-USDT0 to native USDT
  inside its own bridge).
- Flash fee (1 bp): `N * 1 / 10000`
- LayerZero native gas fee (~$0.10 at $600 BNB): negligible.
- Net spread per $1M cycle at 30 bp: `$3,000 - $100 (flash) - $0.10 (lz)`
  ≈ **$2,900**.

## Block pinned
- `FORK_BLOCK = 45_500_000` — placeholder. Re-pin to a window when
  `OFT/Peg` PCS pool slot0 reports `sqrtPriceX96 / 2^96` < 0.9975 (i.e. >
  25 bp discount). TODO scan PCS analytics.

## Risks
- **OFT delivery failure on ETH side** would leave the strategy short
  Peg-USDT on BSC. Mitigated by sizing N ≤ the pre-funded buffer.
- **Adapter address still `address(0)`** in `BSC.sol`. The PoC reads
  `BSC.USDT_OFT_ADAPTER` and falls back to offline simulation if zero.
- **Asymmetric bridge fee** on the return leg (the adapter on Ethereum may
  charge a tier-1 fee). Modelled as a 2 bp tax in the offline PnL.

## Status
- **Positional** (not atomic — LayerZero settlement is ~1-3 min).
- Offline-first PoC; emits `pnl_usd=` block via BSCStrategyBase.
