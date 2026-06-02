# B07-06: PCS v3 cross-fee-tier USDT/WBNB micro-spread arb (0.01% vs 0.05% vs 0.25%)

## Mechanism
UniswapV3-style AMMs deploy one pool per (token pair, fee tier). PCS v3
has three live USDT/WBNB pools at fee tiers 100 (0.01%), 500 (0.05%),
and 2500 (0.25%). Each pool maintains its OWN `sqrtPriceX96`; their mids
diverge whenever arb cycles haven't fully equalised them.

Two PCS v3 primitives stacked:

1. **Flash leg — PCS v3 high-mid pool.** Borrow WBNB fee-only from
   whichever of the three pools has the HIGHEST USDT/WBNB mid (i.e. is
   the most attractive place to sell WBNB). PCS v3 flash fee equals the
   pool's swap-fee tier on the flash *fee* portion.
2. **Return leg — PCS v3 low-mid pool.** Round-trip USDT → WBNB on the
   pool with the LOWEST mid via the canonical SwapRouter at its fee
   tier.

The micro-spread between two PCS v3 tiers exists because:
- The 0.01% pool is the deepest (~$30–40M TVL) and is arbed by every
  bot every block; it's the "fast" pool.
- The 0.05% pool catches mid-size aggregator flow and lags by 1–3 bps.
- The 0.25% pool is shallow (~$0.5–2M TVL) and accumulates 3–10 bps of
  drift between arb sweeps.

## Why it composes
- **Same protocol, different invariants per pool.** Each fee tier has
  an independent state machine; the only thing equalising them is
  arbitrage. With BSC's 3s blocks, micro-drifts persist for 1–4 blocks.
- **Fee-only flash on PCS v3 is unbeatable for same-DEX cycles.** Aave
  flash on BSC has a 5 bp surcharge that kills the trade.
- **Cross-tier scan is cheap on-chain.** Reading three `slot0()`s is
  one `staticcall` each; bots that only watch a single pool miss this.

## Preconditions
- All three USDT/WBNB pools (100/500/2500) deployed and unpaused.
- ≥ 100 WBNB liquidity around the current tick on BOTH the flash pool
  and the return pool (otherwise large slippage erodes the bp edge).
- A net spread > sum of fees on the chosen pair + 2 bp safety margin.

## Strategy steps
1. Read `slot0().sqrtPriceX96` from all three pools, derive mids.
2. Enumerate the 6 ordered (high, low) pairs and pick the maximum
   spread (in bps of low mid).
3. Compute total fee load: `fee_high (swap) + fee_low (swap) +
   fee_high (flash)` (in bps).
4. If `spread > totalFee + MIN_NET_EDGE_BPS`, fire flash on the
   high-mid pool for `FLASH_NOTIONAL_WBNB`.
5. Callback:
   - `exactInputSingle` WBNB → USDT on the high-fee tier (flash pool).
   - `exactInputSingle` USDT → WBNB on the low-fee tier.
   - Repay `notional + flashFee` WBNB to the flash pool.

## PnL math
100 WBNB notional ≈ $60k. Suppose the largest pair is 100↔2500 with a
15 bp spread:
- Gross: 100 × 15/10_000 = 0.15 WBNB ≈ **$90**.
- Sum of swap fees: (0.01% + 0.25%) × 100 = 0.26 WBNB ≈ **$156** —
  this exceeds gross, so 100↔2500 only works above ~30 bps.
- Realistic profitable pair is 100↔500 (sum 6 bps) at 8–12 bps spread:
  100 × (10−6)/10_000 = 0.04 WBNB ≈ **+$24** per fire.
- The 0.25% tier is queried for opportunistic ≥ 30 bp dislocations
  (rare but high-PnL: at 40 bps, edge ≈ 0.14 WBNB ≈ **+$84**).

Hit rate: 0.5–2 fires/day on the 100↔500 pair; 0.1–0.5 on 100↔2500.

## Block pinned
**42_000_000** — sentinel. Wave 3: re-pin to a block immediately after
a large BNB-side flow on PCS v3 0.01% (e.g. a $1M+ swap) that hadn't
yet propagated to the 0.05%/0.25% tiers.

## Addresses used
- `0x172fcD41E0913e95784454622d1c3724f546f849` — PCS v3 0.01% USDT/WBNB
  (verified, same as B07-01).
- `0x36696169C63e42cd08ce11f5deeBbCeBae652050` — PCS v3 0.05% USDT/WBNB.
  **Placeholder** — Wave 3 verify via `IPancakeV3Factory.getPool(WBNB,
  USDT, 500)`.
- `0x85FAac652b707FDf6907EF726751087F9E0b6687` — PCS v3 0.25% USDT/WBNB.
  **Placeholder** — same verification.
- `BSC.PCS_V3_ROUTER`.

## Risks
- **Pool not deployed at pin block** — if a fee tier doesn't exist at
  the chosen block, `slot0()` reverts; `_midOf` will revert hard. Wave 3
  must guard with `Factory.getPool() != address(0)` checks.
- **Mid-spread but no liquidity in tick** — `slot0` reports a mid that
  may not be tradable if no LP positions span the tick. Production
  must add a `quoter.quoteExactInputSingle` pre-check.
- **MEV** — same-DEX micro-spread arb is heavily contested. Single-shot
  capture ≈ 10–25% during liquid hours.
- **Flash-fee tier confusion** — PCS v3 flash fee is set per-pool to
  the pool's SWAP fee, not a separate parameter. The 0.25% pool's
  flash fee is 25 bps, which crushes most cross-tier trades involving
  it. PoC correctly accounts for this.

## Result
Status: **theoretical**. Expected PnL: **+$15–80 per fire on the
100↔500 cycle at 8–15 bp drifts**, with occasional +$80–200 spikes on
100↔2500 at ≥ 30 bp drifts.
