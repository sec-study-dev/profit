# B04-06: PT-USDe BSC + Lista CDP recursive (3-mechanism)

## Mechanism

Three BSC primitives stacked into a self-leveraging fixed-yield position:

1. **Pendle PT-sUSDe-26JUN2025** — buy PT at a fixed USD-denominated
   discount through `swapExactTokenForPt`.
2. **Lista DAO CDP** — deposit PT as collateral and mint lisUSD via
   `IListaInteraction.borrow(token=PT, amount)`. Lista has been listing
   tokenized fixed-yield assets as CDP collateral.
3. **PancakeSwap v3** — swap lisUSD → USDC inside the same tx, then loop
   back into step 1 for a second PT lot.

## Why it composes

- Lista CDP debt is denominated in lisUSD (stable, $1-pegged); collateral
  is PT-sUSDe (also $1-pegged at maturity). Zero FX risk, just basis +
  rate spread.
- PT-sUSDe trades at ~95-97 % entry price (3-5 % carry over 6 months);
  Lista's lisUSD borrow rate is currently ~0-2 %. Net carry: +3-5 % on
  every loop iteration.
- PCS v3 has a deep lisUSD/USDC stable-tier pool (5 bp typical); the
  per-swap slippage on $250k notional is ~5 bp.

## Strategy steps

1. Fund test contract with `EQUITY_USDC = 500_000e18` (USDC is 18-dec on BSC).
2. Loop `LOOP_ITERS = 2`:
   a. `swapExactTokenForPt(market=PT-sUSDe-26JUN2025, ...)` USDC → PT.
   b. `IListaInteraction.deposit(this, PT, ptOut)`.
   c. `IListaInteraction.borrow(PT, ptOut * 55%)` → lisUSD.
   d. `IPancakeV3Router.exactInputSingle(lisUSD → USDC, 5bp)`.
3. Warp past `expiry`.
4. `IListaInteraction.payback(PT, fullDebt)`.
5. `IListaInteraction.withdraw(this, PT, fullLocked)`.
6. `redeemPyToToken(...)` PT → USDC.
7. PnL = `final_usdc - equity_usdc`.

## PnL math

Per 500 k USDC equity, 6-month maturity:
- PT entry discount: 4 % (locked APY ~8 %) on $500 k base = +$20 k
- Second loop adds ~$275 k more PT exposure → +$11 k additional
- lisUSD borrow cost: 2 % on $275 k × 0.5 = -$2.75 k
- PCS swap fees (2 loops × 5 bp × $275 k): -$275
- Gas: ~$3
- **Net: +$28k per $500k held to maturity ≈ +11 % over 6 months**.

## Block pinned

`FORK_BLOCK = 42_000_000` — mid-Q1 2025, ~5-6 months before assumed
26-JUN-2025 expiry.

## Addresses used

- `BSC.PENDLE_ROUTER_V4` = `0x888888888889758F76e7103c6CbF23ABbF58F946`
- `BSC.LISTA_INTERACTION` = `0x1A0D55A5FC2dA0C71ee0ad63D43308f45A16CBe0`
- `BSC.lisUSD` = `0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5`
- `BSC.PCS_V3_ROUTER` = `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4`
- `LOCAL_PT_SUSDE_BSC_MARKET` — placeholder; **TODO verify** on Pendle BSC.

## Risks

- **Lista PT collateral not whitelisted**: PoC degrades after first iter;
  the unleveraged PT cash-and-carry still works.
- **lisUSD/USDC depeg**: small (Lista has a 1% peg-stability module).
- **Liquidation if PT trades < liquidation threshold pre-maturity**:
  unlikely for short maturities but possible if Ethena rates spike.

## Result

Status: **theoretical**. PoC compiles, degrades gracefully. Expected PnL:
**+$25-35k per $500k held to 26-JUN-2025**.
