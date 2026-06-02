# B07-05: PCS v3 ETH/WBNB 0.05% flash → Thena ETH/BNB volatile arb

## Mechanism
A cross-rate variant of B07-01/02/03. Two BSC AMM primitives stacked:

1. **PancakeSwap v3 ETH/WBNB 0.05%** — the primary on-chain ETH/BNB
   cross-rate venue on BSC. ~$3–8M TVL. Binance-Peg ETH (`BSC.WETH`,
   `0x2170...`) is the bridged ETH; pricing is driven by independent
   ETH/USD and BNB/USD legs on other PCS v3 pools, so the cross-rate
   mid moves whenever either base pair moves. We use this as both the
   flash source (fee-only `IPancakeV3Pool.flash()`) and the closing leg.
2. **Thena ETH/WBNB volatile pair** — Solidly fork, ~$0.3–0.8M TVL.
   Volatile (x·y = k) invariant. LPs are sticky for THE bribe emissions
   and don't rebalance against PCS, so this pair lags by 15–60 bps
   whenever ETH/BNB moves materially.

Atomic arb: borrow WBNB on PCS v3 → buy ETH on Thena at the lagged
(cheap-ETH) price → sell ETH on PCS v3 at the fresh price → repay.

## Why it composes
- **Cross-rate has a different mispricing distribution** than quote-pair
  arbs. ETH/BNB mispricing fires on ETH-relative-to-BNB moves, which are
  uncorrelated with the BNB/USD candles that drive B07-01. Diversifies
  the hit-rate clock.
- **PCS v3 flash on the closing pool** keeps the cycle two-hop atomic; no
  Aave/Balancer routing or surcharge.
- **Thena's THE-bribed LPs** systematically under-arbitrage ETH/BNB
  because their P&L target is gauge bribes, not slippage.

## Preconditions
- ETH/BNB cross-rate moved ≥ 0.3% in the prior 1–2 BSC blocks.
- Thena ETH/WBNB volatile pair exists and is unpaused.
- PCS v3 0.05% ETH/WBNB pool has ≥ 500 WBNB in the active tick range.

## Strategy steps
1. Read PCS v3 `slot0().sqrtPriceX96`, derive `pcs_wbnb_per_eth`.
2. Read Thena pair reserves, derive `thena_wbnb_per_eth`.
3. If Thena's mid is BELOW PCS's (i.e. ETH is cheaper on Thena) by ≥
   MIN_SPREAD_BPS, fire `pool.flash()` borrowing WBNB.
4. Callback:
   - Swap WBNB → ETH on Thena (1 hop, volatile).
   - Swap ETH → WBNB on PCS v3 0.05% via `exactInputSingle`.
   - Transfer `notional + fee` WBNB back to the pool.

## PnL math
500 WBNB notional ($300k @ $600/BNB) at a 50 bp Thena lag:
- Gross edge: 500 × 50/10_000 = 2.5 WBNB ≈ **$1500**.
- Thena fee: 0.20% × 500 = 1.0 WBNB ≈ **$600**.
- PCS v3 swap fee: 0.05% × 500 ≈ **$150**.
- PCS v3 flash fee: 0.05% × 500 ≈ **$150**.
- **Net at 50 bps: 1.0 WBNB ≈ +$600.** Break-even ≈ 30 bps; +$200 at 40 bps.

Hit rate: 1–3 fires/day on ETH/BNB cross-rate volatility days.

## Block pinned
**42_000_000** — sentinel. Wave 3: re-pin after an ETH/USD candle ≥ 0.5%
where BNB/USD moved < 0.3% (i.e. an ETH-led cross-rate move).

## Addresses used
- `0x9fceC0d29ad9C9b6C7DDA51AA2cE1Db5fEdE9777` — PCS v3 0.05% ETH/WBNB.
  **Placeholder** — Wave 3 verify via `IPancakeV3Factory.getPool(WETH,
  WBNB, 500)`.
- `0x4BBA1018b967e59220b22cA03b68bb1Fd72a371c` — Thena ETH/WBNB volatile.
  **Placeholder** — verify via `Router.pairFor(WETH, WBNB, false)`.
- `BSC.THENA_ROUTER`, `BSC.PCS_V3_ROUTER`, `BSC.WETH`, `BSC.WBNB`.

## Risks
- **Bridged-ETH depeg** — if BSC.WETH (Binance-Peg ETH) depegs from CEX
  ETH (bridge halt, custody event), both Thena and PCS track the on-chain
  rate so internal spread compresses.
- **Thena reserve too small** — 500 WBNB into a $0.5M ETH/BNB pool causes
  ~30% impact; production must size dynamically. PoC fixed-size as a
  Wave 3 witness.
- **MEV** — ETH/BNB cross is under-monitored vs. BNB/USDT but bots are
  beginning to cover it. Single-shot capture ≈ 30–60%.
- **PCS v3 tick crossing** — 0.05% pool has tick spacing 10; 500 WBNB
  swap may cross several initialised ticks. `sqrtPriceLimitX96 = 0` is
  unsafe in prod; PoC accepts it for clarity.

## Result
Status: **theoretical**. Expected PnL: **+$200–1000 per fire at 40–80 bp
Thena lag**, complementing B07-01/02/03 with a cross-rate hit-rate clock.
