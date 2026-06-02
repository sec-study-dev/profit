# B12-07: solvBTC in Wombat BTC pool + Avalon collateral 3-mech

## Mechanism (3-mech)
1. **Wombat BTC stable-style pool** — Wombat lists a BTC pool that
   prices solvBTC vs BTCB at near-par. LPs earn AMM swap fees +
   WOM emissions (~3.5 % APY at the pinned block) without taking
   meaningful IL because both assets are 1 BTC equivalents.
2. **Avalon Lending Pool** — supply solvBTC (40 % slice) as collateral
   and borrow USDX. Avalon publishes ~65 % LTV for BTC-LSDs.
3. **PCS v3 USDX -> USDT -> BTCB recycled into Wombat** — the
   borrowed USDX is recycled into BTCB and deposited into the same
   Wombat BTC pool, so the borrow leg ALSO earns LP fees + WOM.

## Why it composes
- A single asset (solvBTC) earns native restake APY (~2 %), Wombat
  LP fees, WOM emissions, and Avalon supply incentive — four yield
  sources from one delta.
- BTC delta is preserved end-to-end (the borrow leg gets recycled
  back into a BTC LP, not held as USDX).
- Wombat's near-par pricing means the recycled BTCB and the original
  solvBTC both earn the same WOM gauge rate per dollar of TVL.

## Strategy steps (10 BTC notional, 30-day horizon)
1. Mint or buy 10 solvBTC.
2. Deposit 6 solvBTC into Wombat BTC pool.
3. Supply 4 solvBTC to Avalon, borrow USDX at safety = 90 %.
4. Swap USDX -> USDT -> BTCB on PCS v3 (5 bp tier).
5. Deposit BTCB into Wombat BTC pool.
6. Hold 30 days; harvest WOM emissions; redeem.

## PnL math (10 BTC principal, 30-day horizon, BTC = $65k)
- Wombat LP fees on 60 % slice: 0.6 * 0.8 % = +0.48 % APY.
- WOM emissions on Wombat TVL (60 % + ~23 % recycled): +2.92 % APY.
- Avalon supply APY (40 %): +0.72 % APY.
- USDX borrow drag (23 %): -0.35 % APY.
- solvBTC native restake (all 10 BTC): +2.00 % APY.
- Swap drag: -0.20 % APY.
- **Blended APY: +5.57 %.**
- 30-day carry: 5.57 * 30/365 = **+0.458 %** on principal.
- Dollar PnL: 10 BTC * $65k * 0.458 % = **~ +$2,977** + ~$2,000 WOM
  emissions = **~ +$4,977 net**.

Gas: deposit + supply + borrow + multi-hop + deposit + claim ~ 2.5M
gas, ~$1.50.

## Block pinned
**47_600_000** (early-2025; assumes Wombat BTC pool live and Avalon
solvBTC market live). Re-pin once verified.

## Addresses used
- `BSC.solvBTC`, `BSC.BTCB`, `BSC.WOM`, `BSC.USDT`.
- `BSC.AVALON_LENDING_POOL`, `BSC.WOMBAT_ROUTER`, `BSC.PCS_V3_ROUTER`.
- `LOCAL_WOMBAT_BTC_POOL = 0x...B12071` — Wombat BTC pool (TODO verify).
- `LOCAL_SOLV_MINTER = 0x...B12072` — Solv router (TODO verify).
- `LOCAL_USDX = 0xf3527eF8...` — Avalon USDX (TODO verify).

## Risks
- Wombat BTC pool may not list both solvBTC and BTCB at the pinned
  block. Mitigation: PoC probes via `getAmountOut`; falls back to
  offline branch.
- WOM token price collapse cuts the emission leg by ~50 % (largest
  yield component). Mitigation: rotate to PT or harvest weekly.
- Wombat coverage-ratio LP withdrawals can charge a haircut on the
  exit leg; size to <10 % of pool TVL.
- Avalon liquidation risk during BTC drawdown; HF buffer >= 1.20.

## Result
Status: **theoretical** (multiple TODO-verify; PoC compiles, guards
every external call). Expected PnL: **+0.4 - 0.6 % over 30 days on
10 BTC principal + WOM emissions ~ $2k**.
