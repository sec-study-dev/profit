# B12-05: pumpBTC + Avalon + Pendle PT-pumpBTC 3-mech stack

## Mechanism (3-mech)
1. **pumpBTC restake** — pumpBTC mints 1:1 against BTCB and delegates
   to Babylon validators, earning native restake yield + project
   points. Native APY at the pinned block ~ 5 % gross.
2. **Avalon Lending Pool** — supply pumpBTC as collateral (~60 % LTV),
   borrow USDX. The recursive loop (3 iterations) levers the pumpBTC
   exposure to ~2.0x.
3. **Pendle PT-pumpBTC sleeve** — peel 30 % of the levered position
   into a fixed-rate PT-pumpBTC hold on Pendle BSC, locking in ~9 %
   implied APY to expiry. This is an over-allocation to the highest-yield
   leg without sacrificing the variable-rate exposure on the other 70 %.

## Why it composes
- pumpBTC native yield is variable, PT-pumpBTC yield is fixed: the
  sleeve mix captures both regimes from a single asset.
- Avalon collateral haircut on PTs is ~50 % vs 60 % for pumpBTC, so
  we deliberately put the PT outside the borrow base (it's a sleeve,
  not collateral) to avoid the LTV haircut.
- Two of the three legs (pumpBTC + PT) are BTC-denominated, so the
  whole position is delta-1 BTC with two independent yield sources.

## Strategy steps (8 BTC notional, 60-day horizon)
1. Spot-fund 8 BTC of pumpBTC.
2. Three Avalon recursive iterations at safety = 90 % of
   `availableBorrowsBase`, USDX -> USDT -> BTCB -> pumpBTC.
3. Peel 30 % of final pumpBTC balance, buy PT-pumpBTC on Pendle BSC.
4. Hold 60 days; PT pulls to par (~+1.8 % accrual on sleeve).
5. Unwind: redeem PT -> pumpBTC, withdraw, repay USDX, sell residual.

## PnL math (8 BTC principal, 60-day horizon, BTC = $65k)
- Levered pumpBTC carry (70 % slice): 2.0x * 5 % - 1.0x * 1.5 % = +8.5 %
  APY.
- PT-pumpBTC sleeve (30 % slice): +9 % APY (fixed at entry).
- Blended APY: 0.70 * 8.5 + 0.30 * 9.0 - 0.6 (swap drag) = +8.55 %.
- 60-day carry: 8.55 * 60/365 = **+1.41 %** on principal.
- Dollar PnL: 8 BTC * $65k * 1.41 % = **~ +$7,330**.

Gas: 3 supply/borrow/multi-hop + Pendle buy ~ 2.4M gas, ~$1.50.

## Block pinned
**47_800_000** (early-2025; assumes Pendle BSC PT-pumpBTC market live
and Avalon listed pumpBTC). Re-pin once confirmed.

## Addresses used
- `LOCAL_PUMPBTC = 0xF9CB4a9C9a3e3a4cFc89b8F9D6Aa9C4Bd2bF1d11` — pumpBTC
  ERC20 (TODO verify).
- `LOCAL_PUMPBTC_MINTER = 0x...B12051` — pumpBTC mint router (TODO verify).
- `LOCAL_PENDLE_MARKET_PUMPBTC = 0x...B12052` — Pendle PT/SY/YT market
  for pumpBTC (TODO verify).
- `LOCAL_USDX = 0xf3527eF8...` — Avalon USDX (TODO verify).
- `BSC.AVALON_LENDING_POOL` — Avalon Aave V3 fork.
- `BSC.PENDLE_ROUTER_V4` — Pendle Router V4 (TODO verify on BSC).
- `BSC.PCS_V3_ROUTER` — PCS v3 SwapRouter.

## Risks
- pumpBTC issuance pause or Babylon slashing event torpedoes the
  variable APY leg. Mitigation: PT sleeve locks 30 % of yield.
- PT-pumpBTC pre-expiry depeg amplified by 2.0x leverage on
  underlying. HF buffer >= 1.15.
- Avalon may not list pumpBTC at the pinned block; PoC degrades to
  offline branch.

## Result
Status: **theoretical** (multiple TODO-verify addresses; offline
branch models the 3-mech blend). Expected PnL: **+1.2 - 1.6 % over
60 days on 8 BTC principal**.
