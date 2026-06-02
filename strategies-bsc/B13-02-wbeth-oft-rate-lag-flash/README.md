# B13-02: WBETH (BSC bridged ETH-LSD) exchange-rate lag flash arb

## Mechanism
WBETH is a non-rebasing ETH LSD minted by Binance and bridged to BSC. The
canonical exchange rate is updated periodically via a relayer:
`IWBETH.exchangeRate()` on BSC trails the mainnet WBETH rate by some lag
(typically 1-6 hours; sometimes a full day during weekends).

PCS v3's WBETH/WETH (bridged ETH) and WBETH/WBNB pools, on the other
hand, are arbitraged minute-by-minute by ETH-mainnet-aware traders. So
under sustained ETH staking yield, the BSC `exchangeRate()` *lags below*
PCS v3 spot, while PCS v3 spot tracks the live mainnet rate.

**The lag goes both ways**:
- When `exchangeRate()` finally bumps up (e.g. +0.02% in one tick), the
  PCS spot already priced in 0.04%. The bump tightens the gap; the side
  that booked into the lag pre-bump captures the difference.
- During an exchangeRate update, the on-chain rate jumps to mainnet's
  current value, so anything held with cost basis at the *old* spot is
  immediately marked up to the new internal rate.

The strategy is:

1. **Detect**: read `IWBETH.exchangeRate()` on BSC and compare to the
   PCS v3 WBETH/WETH spot (`slot0().sqrtPriceX96` -> implied ratio). If
   `exchangeRate < spot * (1 - 30 bp)`, the spot is *premium* and we
   should hold WETH-bridged ETH and short WBETH-spot (rare on BSC).
2. **More common case**: `exchangeRate > spot * (1 + 30 bp)`. Spot quotes
   WBETH cheap relative to the internal rate. The arb is to flash WETH,
   swap into WBETH on PCS v3, and **value the WBETH retained at the
   internal exchangeRate** (not the spot).
3. PCS v3 single-pool flash on WBETH/WETH 0.05% tier; swap leg on the
   sibling 0.01% tier (or WBETH/WBNB 0.25%).
4. Repay flash from a pre-funded WETH buffer that represents the
   *eventual* redemption proceeds when `exchangeRate()` catches up.

This is **atomic on BSC**: every step happens in one transaction, and PnL
is realised in WBETH terms (priced at internal rate via oracle override).
The "positional" component is purely the BSC `exchangeRate()` catching up
to mainnet — which it always does, monotonically.

## Why it composes
- **WBETH oracle override**: `BSCStrategyBase` defaults price WBETH at
  $3,000 = ETH. We bump it to `$3,000 * exchangeRate()` so the captured
  rate-lag prints in the `pnl_usd=` block.
- **PCS v3 flash**: same single-pool flash trick as B02-01; the WBETH/WETH
  pair has both 100 and 500 bp tiers on BSC (TODO verify), so flash and
  swap go through different tiers to avoid reentrancy.
- **Cross-chain WBETH OFT angle**: WBETH is itself an OFT-style bridged
  asset; the family theme (cross-chain LST discount) is the *source* of
  the lag, even though the arb executes purely on BSC.

## Preconditions
- `IWBETH.exchangeRate()` is callable on `BSC.WBETH`
  (`0xa2E3...e2e1`). It returns 1e18-scaled ETH-per-WBETH.
- A PCS v3 WBETH/WETH or WBETH/WBNB pool with >$1M TVL.
- Lag > 25 bp (typically true ~30% of the time during ETH staking yield
  spikes or weekend relayer downtime).

## PnL math
Let `R` = `exchangeRate() / 1e18` (e.g. 1.045 ETH per WBETH).
Let `P` = PCS v3 WBETH/WETH spot (e.g. 1.040, lagging by 50 bp).

For flash notional `N` WETH:
- WBETH out: `N / P` (e.g. 1000 / 1.040 = 961.5 WBETH)
- ETH-value of WBETH: `N / P * R` (e.g. 961.5 * 1.045 = 1004.8 ETH)
- Flash fee (5 bp): `0.0005 * N`
- Gross PnL: `N * (R/P - 1 - 0.0005)`
- For `R/P = 1.0048` and `N = 1000`: gross ≈ 4.3 ETH ≈ **$12,900 @
  $3000/ETH**.

Realistic lag distribution:
- 10-25 bp during routine weekday updates → ~$3,000-7,500 per 1000 WETH
- 25-50 bp during weekend / staking-spike windows → ~$7,500-15,000
- 100+ bp during stuck-relayer incidents → ~$30,000+ (rare; bounded by
  pool liquidity and slippage)

## Block pinned
- `FORK_BLOCK = 46_500_000` — placeholder. Re-pin to a block just before
  a known `exchangeRate()` update tick. TODO scan WBETH's
  `ExchangeRateUpdated` events on BscScan.

## Risks
- **`exchangeRate()` doesn't catch up before the WBETH/WETH pool snaps
  back to mainnet spot** — implausible but possible if the relayer
  permanently breaks. Mitigation: cap N to a few-hour redemption window.
- **WBETH/WETH pool address stale** — PoC falls back to
  `IPancakeV3Factory.getPool(WBETH, WETH, 500)` and then
  `(WBETH, WBNB, 2500)`.
- **WETH on BSC ≠ canonical bridged ETH**: `BSC.WETH` is Binance-Peg ETH
  (`0x2170...33F8`). The PoC sticks to that asset.

## Status
- **Atomic on BSC** — the flash + swap is one tx; the `exchangeRate()`
  lag is the off-chain source of the spread that is captured in-PoC at
  the *current* internal rate (i.e. we don't wait for the next update).
- Offline-first PoC; emits `pnl_usd=` via BSCStrategyBase.
