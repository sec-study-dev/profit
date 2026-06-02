# B07-02: PCS v3 BTCB/USDT 0.05% flash → Thena BTCB/USDT volatile arb

## Mechanism
Binance-Peg BTCB is Binance's wrapped-BTC token and trades 1:1 with CEX BTC
within ~5 bps. The on-chain mirror lags slightly during fast moves because:

1. **PancakeSwap v3 BTCB/USDT 0.05%** — primary on-chain BTCB venue.
   ~$15M TVL. Arbed against CEX every block. We borrow BTCB here via
   `IPancakeV3Pool.flash()`; the 0.05% fee pool is the cheapest BTCB
   flash source on BSC (a 0.01% tier doesn't have BTCB liquidity at most
   blocks).
2. **Thena BTCB/USDT volatile pair** — secondary venue, ~$0.5–1M TVL.
   Volatile (x·y = k) invariant. LPs are sticky for THE bribes and don't
   actively rebalance, so the Thena mid lags PCS v3 by 10–30 bps during
   BTC candles ≥ 0.5%.
3. **Atomic arb** — same shape as B07-01 but the asset is BTCB and the
   fee load is higher (PCS v3 0.05% × 2 = 10 bps vs. 0.01% × 2 = 2 bps in
   B07-01), so MIN_SPREAD_BPS is set to 30.

## Why it composes
- **BTC carry** — BSC bots focus on BNB pairs; BTCB is under-monitored
  relative to its TVL. Edge persistence is therefore higher than on
  BNB/USDT (~2× longer half-life).
- **PCS v3 0.05% flash** — even at the higher fee tier, BTCB/USDT 0.05%
  is cheaper than any cross-DEX BTCB router (Wombat charges 1–4 bps
  haircut + ~2 bps depeg risk on btcb→usdt; PCS v3 flash is fee-only,
  i.e. you pay the swap fee just on the flash *fee* portion).
- **Same callback closes the loop** — atomic, no positional risk.

## Preconditions
- Block where Thena's BTCB pair has not been synced to CEX for ≥ 1 BSC
  block (~3s). Highest hit-rate around BTC funding-flips (00:00, 08:00,
  16:00 UTC).
- PCS v3 0.05% BTCB/USDT pool has ≥ 3 BTCB available around current tick.

## Strategy steps
1. Read PCS v3 `slot0()`, compute `btc_usdt_pcs` mid.
2. Read Thena `getReserves()`, compute `btc_usdt_thena` mid.
3. If `thena > pcs + MIN_SPREAD_BPS`, size BTCB notional from
   FLASH_NOTIONAL_USDT / pcs_mid, then call `pool.flash()`.
4. In callback:
   - Sell flashed BTCB → USDT on Thena.
   - Buy USDT → BTCB back on PCS v3 0.05% via `exactInput`.
   - Transfer `borrowed + fee0 (or fee1)` BTCB back to the pool.
5. Profit = (BTCB out of PCS v3 swap) − (BTCB borrowed + fee).

## PnL math
200k USDT notional ≈ 3 BTCB @ $65k. At a 40 bps Thena lag:
- Gross BTCB-equivalent edge: 3 × 40/10_000 ≈ 0.012 BTCB ≈ **$780**.
- Thena fee: 0.20% × 3 BTCB ≈ 0.006 BTCB ≈ **$390**.
- PCS v3 swap fee (return): 0.05% × 3 BTCB ≈ 0.0015 BTCB ≈ **$98**.
- PCS v3 flash fee: 0.05% × 3 BTCB ≈ 0.0015 BTCB ≈ **$98**.
- Net at 40 bps: **+$194**.

At 30 bps the strategy is roughly break-even; at 50 bps it's +$350. Hit
rate: ~3–8 fires/day on a fast-moving BTC day; ~0–2 on a quiet day.

## Block pinned
**42_000_000** — sentinel. Wave 3: re-pin to a block after a BTC candle
> 1% within the prior 2 BSC blocks.

## Addresses used
- `0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4` — PCS v3 0.05% BTCB/USDT.
- `0x7561EEe90e24F3b348E1087A005F78B4c8453524` — Thena BTCB/USDT volatile.
  **Placeholder** — Wave 3 verify.
- `BSC.THENA_ROUTER` / `BSC.PCS_V3_ROUTER` from `src/constants/BSC.sol`.

## Risks
- **BTCB depeg** — if BTCB depegs from CEX BTC (e.g. Binance proof-of-
  reserves event), the on-chain spread vs. CEX widens but Thena and PCS
  v3 both track it together, so the arb spread within BSC stays small.
- **Thena BTCB reserve drains** — at 3 BTCB notional on a $1M pool, the
  swap may consume 30% of reserves, causing 15%+ price impact. Production
  code must dynamically size to ≤ 5% of Thena reserves; PoC is fixed-size
  as a witness.
- **Fee tier change** — if PCS v3 governance flips this pool's fee, the
  flash cost changes silently; production must read `pool.fee()` and
  recompute MIN_SPREAD.
- **MEV** — BTCB/USDT is monitored by ~10–15 known BSC searchers; mempool
  visibility is high. Realistic single-shot capture <30% during liquid
  hours; higher during exchange downtimes.

## Result
Status: **theoretical** (BSC RPC not configured; PoC compiles, skips
when spread < MIN_SPREAD_BPS). Expected PnL: **+$150–500 per fire at
40–80 bp Thena lag**, with ~50% of edge eaten by Thena's 0.20% fee.
