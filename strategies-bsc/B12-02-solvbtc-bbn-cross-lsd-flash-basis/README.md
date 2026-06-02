# B12-02: solvBTC ↔ solvBTC.BBN cross-BTC-LSD basis flash arb

## Mechanism
Atomic single-block PCS v3 flash arb on the **internal Solv BTC-LSD
conversion rate** vs the **market price** between solvBTC and its
Babylon-restaked wrapper solvBTC.BBN. Three primitives:

1. **Solv internal `stake` / `unstake`** — solvBTC.BBN is minted from
   solvBTC at the protocol-defined exchange rate
   `pricePerShare_BBN = TotalSolvBacking / TotalSupply_BBN`. The rate is
   monotonically rising due to Babylon yield (≈ +1.0-1.5 % cumulative
   appreciation over the BBN's lifetime to-date at the pinned block).
   The *true* internal value of 1 solvBTC.BBN at the pinned block is
   ~1.012 solvBTC.
2. **PCS v3 secondary market** — both solvBTC and solvBTC.BBN trade on
   PCS v3 vs BTCB / WBNB. During incentive-emission events, the
   solvBTC.BBN secondary market often *underprices* the internal rate
   by 20-50 bp because users dump their farmed BBN tokens. Conversely,
   during Babylon airdrop windows it can *overshoot* by 30-80 bp.
3. **PCS v3 flash** — borrow a notional solvBTC from the
   solvBTC/WBNB or solvBTC/BTCB v3 pool, route through the cheap leg
   (mint or buy), unwind through the expensive leg (sell or unstake),
   repay flash atomically.

## Why it composes
- The basis between `pricePerShare_BBN` (slow, deterministic) and the
  secondary-market price (noisy, immediate) is mean-reverting in a
  single block — `unstake` may be cooldown-gated, but `stake` is
  always open, so the *premium* direction (BBN trades above intrinsic)
  is always arbable atomically; the *discount* direction needs a
  secondary-market sell to monetize.
- Atomicity is enforced by the PCS v3 flash: if the spread vanishes
  mid-block (other arb fills), the trade reverts and only the flash fee
  is at risk.

## Preconditions
- BSC block where solvBTC / solvBTC.BBN basis ≥ 25 bp (absolute) net of
  expected swap + flash fees (5 bp PCS v3 fee + 5 bp slippage = 10 bp
  cost floor).
- solvBTC/WBNB or solvBTC/BTCB PCS v3 pool with > $1M liquidity (TODO
  verify pool addresses + fee tiers via Factory).
- Solv `stake()` open (mint not whitelist-gated at the pinned block).

## Strategy steps (premium-direction trade: BBN trades above intrinsic)
1. PCS v3 `flash(solvBTC notional, 0)` on solvBTC / WBNB 500-bp pool.
2. In callback:
   - `Solv.stake(notional)` → mint `notional / pricePerShare_BBN`
     solvBTC.BBN at intrinsic rate.
   - PCS v3 `exactInput` swap `solvBTC.BBN → solvBTC` on the alt pool
     (e.g., solvBTC.BBN / BTCB → solvBTC via two-hop).
   - Receive more solvBTC than `notional + flashFee` if the basis was
     real.
   - Repay flash; keep the residual as profit.
3. Discount-direction (BBN < intrinsic) symmetric: flash solvBTC.BBN,
   `unstake` to solvBTC, sell solvBTC for solvBTC.BBN via PCS v3,
   repay. **Requires cooldown bypass** — Solv `unstake` typically has
   a 7-day delay, so the discount arb requires a synthetic short via
   sUSDe-style pre-funded buffer. PoC implements only the premium leg
   atomically.

## PnL math (1,000 solvBTC notional, single trade)
Indicative basis = 35 bp (mid-cycle premium) at the pinned block:
- Flash notional: 1,000 solvBTC ($65M equivalent).
- Mint at intrinsic 1.012 → receive 1,000 / 1.012 = 988.14 solvBTC.BBN.
- Sell 988.14 solvBTC.BBN at market premium of 35 bp on intrinsic
  (i.e., 1.0155 solvBTC per solvBTC.BBN) → receive 988.14 × 1.0155 =
  1,003.45 solvBTC.
- Flash fee at 5 bp = 0.5 solvBTC.
- Pool swap fee at 5 bp = 0.49 solvBTC (on 988.14 BBN traded).
- Slippage drag at notional size: ~10 bp = 1.0 solvBTC.
- Gross gain: 1,003.45 − 1,000 = 3.45 solvBTC.
- Net gain after fees: 3.45 − 0.5 − 0.49 − 1.0 = **1.46 solvBTC**
  ≈ **$94,900** at BTC=$65k.

Gas: ~700k for flash + 2 swaps + mint ≈ $0.50.

## Block pinned
**47_200_000** (Q1-2025 estimate where Babylon incentive cliff causes
BBN premium spikes). Re-pin once BSC_RPC_URL is available.

## Addresses used
- `0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7` — solvBTC.
- `0x1346b81C8E3FE38d6cFc7e1B1cdF92C6b0050BFE` — solvBTC.BBN.
- `0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c` — BTCB.
- `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` — WBNB.
- `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` — PCS v3 SwapRouter.
- `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` — PCS v3 Factory.
- `LOCAL_SOLV_BBN_MINTER` — Solv stake/unstake router (placeholder
  `0x00...B12021`); TODO verify against Solv docs.
- `LOCAL_POOL_SOLVBTC_WBNB_500` — PCS v3 solvBTC/WBNB 0.05% tier
  (resolved via Factory at runtime).

## Risks
- **Spread vanishes mid-block**: bot competition closes the basis
  faster than expected; flash reverts and we eat ~0.5 solvBTC flash
  fee. Mitigation: assert `min_solvBTC_received >= notional + fees`
  inside the callback.
- **Cooldown on unstake**: only the premium direction is atomically
  monetizable. Discount-direction PnL accrues over 7 days and exposes
  the position to BTC price drift (delta-hedge with BTCB short).
- **Pool address skew**: PCS v3 pool addresses must be resolved via
  Factory at the pinned block; hardcoded addresses are placeholders.
- **Solv `stake` pause / whitelist**: if Solv flips the mint mode,
  the premium leg reverts. PoC wraps the stake call in try/catch.

## Result
Status: **theoretical** (BSC RPC not configured; PoC compiles and
runs the offline accounting branch). Expected gross PnL per
opportunity window: **+1.0 – 2.0 solvBTC (~$65 – 130k) per atomic
trade** at 1,000 solvBTC flash size, conditional on observed basis
≥ 30 bp.
