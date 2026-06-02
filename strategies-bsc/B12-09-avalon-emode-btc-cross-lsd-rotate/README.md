# B12-09: Avalon eMode BTC-correlated cross-LSD rotate 3-mech

## Mechanism (3-mech)
1. **Avalon BTC eMode** — Aave V3-style efficiency-mode category for
   BTC-correlated assets (BTCB, solvBTC, solvBTC.BBN, pumpBTC,
   enzoBTC). eMode raises LTV from ~65 % standard to ~93 % and the
   liquidation threshold to ~95 %. Within the category the borrower
   gets near-1:1 collateral-to-debt allowed on BTC <-> BTC pairs.
2. **Avalon cross-LSD borrow: solvBTC.BBN collateral -> BTCB debt** —
   borrow the *cheapest* BTC-correlated asset against the
   *highest-yielding* BTC-LSD. The eMode rate spread is the edge:
   solvBTC.BBN supply yield (~3.5 %) vs BTCB borrow APR (~0.8 %).
3. **Venus vBTCB supply leg** — take 25 % of the borrowed BTCB and
   supply it to Venus's vBTCB market (different lending protocol)
   to capture Venus supply APY + XVS emissions. This is the inter-
   protocol rate-spread leg: Avalon BTCB borrow at ~0.8 % vs Venus
   BTCB supply at ~1.2 % = +40 bp risk-free on that slice.
4. The remaining 75 % of borrowed BTCB cycles back through Solv
   minter (BTCB -> solvBTC -> solvBTC.BBN) and re-supplies to
   Avalon, building the leverage loop.

## Why it composes
- eMode unlocks ~4.2x effective leverage in 3 iterations at 85 %
  safety (vs ~2.5x in normal mode). All collateral is BTC-correlated,
  so liquidation risk is bounded by the solvBTC.BBN <-> BTCB price
  ratio (typically <1 % deviation).
- Borrowing BTCB instead of USDX eliminates the stable-leg swap
  drag entirely on the main path (with a USDX fallback if eMode
  BTCB borrow is disabled).
- Venus is a DIFFERENT lending venue, so the supply-side leg captures
  rate divergence between Avalon and Venus markets for the same asset.

## Strategy steps (15 BTC notional, 30-day horizon)
1. `setUserEMode(BTC_EMODE_CATEGORY)` on Avalon.
2. Three Avalon iterations:
   a. Supply solvBTC.BBN.
   b. Borrow BTCB at safety 85 %; fallback to USDX + PCS v3 swap
      if BTCB borrow caps are hit.
   c. Send 25 % of borrowed BTCB to Venus `vBTCB.mint()`.
   d. Mint solvBTC.BBN from remaining BTCB via Solv minter.
3. Hold 30 days; harvest XVS + Avalon incentives; unwind.

## PnL math (15 BTC principal, 30-day horizon, BTC = $65k)
Indicative rates at the pinned block:
- eMode safety = 85 %, 3 loops -> ~4.2x effective leverage.
- solvBTC.BBN restake APY: 3.5 %.
- BTCB borrow APR on Avalon (eMode): 0.8 %.
- Venus vBTCB supply APY + XVS: 1.2 % on the 25 % slice * 3.2x lev.
- Swap drag on USDX fallback (~30 % of iterations): -0.15 % APY.

Blended:
- Levered restake (4.2x * 3.5 %): +14.70 % APY.
- BTCB borrow drag (3.2x * 0.8 %): -2.56 % APY.
- Venus inter-protocol spread (3.2x * 0.25 * 1.2 %): +0.96 % APY.
- Swap drag: -0.15 % APY.
- **Total: +12.95 % APY.**

30-day carry: 12.95 * 30/365 = **+1.065 %** on principal.
Dollar PnL: 15 BTC * $65k * 1.065 % = **~ +$10,384**.

Gas: 3 supply + 3 borrow + 3 Venus mint + 3 Solv mint chain
~ 3.0M gas, ~$1.80.

## Block pinned
**47_950_000** (early-2025; assumes Avalon eMode live with
BTC-correlated category). Re-pin once confirmed.

## Addresses used
- `BSC.AVALON_LENDING_POOL`, `BSC.vBTCB`, `BSC.PCS_V3_ROUTER`.
- `BSC.solvBTC_BBN`, `BSC.solvBTC`, `BSC.BTCB`, `BSC.USDT`.
- `BTC_EMODE_CATEGORY = 2` — Avalon eMode category id (TODO verify).
- `LOCAL_USDX = 0xf3527eF8...` — Avalon USDX fallback path (TODO verify).
- `LOCAL_SOLV_BBN_MINTER = 0x...B12091` — Solv router (TODO verify).

## Risks
- eMode not enabled at the pinned block; PoC falls back to standard
  mode (effective leverage drops to ~2.5x, APY ~ +8.5 %).
- BTCB borrow caps reached; PoC falls back to USDX swap leg.
- solvBTC.BBN <-> BTCB depeg amplifies liquidation risk at 4.2x
  leverage; safety 85 % keeps HF >= 1.10 buffer.
- Venus XVS emissions can drop sharply (governance-controlled);
  this leg is the smallest in the blend so degradation is bounded.

## Result
Status: **theoretical** (eMode category id and Solv minter selectors
are TODO verify; PoC guards every call). Expected PnL: **+0.8 - 1.3 %
over 30 days on 15 BTC principal** at 4.2x eMode leverage.
