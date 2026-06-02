# B12-04: PT-solvBTC.BBN (Pendle BSC) + Avalon collateral stack

## Mechanism
Three BSC primitives stacked into a fixed-rate BTC carry:

1. **Pendle PT-solvBTC.BBN on BSC** — Pendle lists solvBTC.BBN markets on
   BSC; PT-solvBTC.BBN trades at an implied yield that prices in
   `Babylon yield + Avalon supply incentive + points` over the term to
   expiry. At the pinned block we assume PT-solvBTC.BBN trades at ~7-9 %
   implied APY to maturity (60-90 days out), giving a fixed-rate BTC
   carry well above Avalon's USDX borrow APR.
2. **Avalon Lending Pool** — Avalon lists PT-solvBTC.BBN as collateral
   (Aave V3 fork with Pendle-aware adapter, common in recent BTC-LSD
   protocols). LTV is conservative (~50 %) due to PT term-risk, but
   sufficient to borrow USDX and re-buy PT in a smaller recursive loop.
3. **PCS v3 USDX/USDT** — same swap leg as B12-01/03 for recycling the
   borrowed USDX into BTCB (and re-minting solvBTC.BBN → buy PT).

## Why it composes
- PT yield is **fixed at entry** for the full term — there is no IRM
  risk on the long leg. The short leg (USDX borrow) has variable rate,
  but Avalon's incentive program typically rebates a large share of
  the nominal borrow cost.
- Holding to expiry guarantees `PT → underlying` redemption at 1:1
  (no AMM price risk on exit), so the strategy is effectively a
  delta-1 hold of solvBTC.BBN with a known yield differential.
- The Avalon LTV haircut on PTs is the only mechanism slack: at 50 %
  LTV with two iterations, effective leverage is ~1.5×, lifting the
  net APY meaningfully above pure PT.

## Preconditions
- Pendle BSC has a live PT-solvBTC.BBN market at the pinned block (TODO
  verify; Pendle expansion to BSC happened mid-2024).
- Avalon accepts PT-solvBTC.BBN as collateral with LTV ≥ 40 % (TODO
  verify; if not, the strategy degrades to a one-shot PT hold).
- PT remaining maturity ≥ 30 days at entry; ≤ 120 days to keep
  implied-APY meaningful.

## Strategy steps (5 BTC notional, 90-day term to PT expiry)
1. Spot-buy PT-solvBTC.BBN via Pendle router or PT/SY AMM with 5 BTC
   notional of solvBTC.BBN.
2. Iteration 1:
   - `IAvalonLendingPool.supply(PT-solvBTC.BBN, balance, address(this), 0)`.
   - Read `availableBorrowsBase`; borrow `0.9 × availableBorrowsBase`
     in USDX.
   - PCS v3 USDX → USDT → BTCB → mint solvBTC.BBN → buy more PT-solvBTC
     on Pendle. Slippage cap 30 bp.
   - Re-supply newly bought PT.
3. Iteration 2 (one more loop to hit ~1.6× effective leverage at LTV
   0.50).
4. Hold to PT expiry (~90 days). At expiry: `PT → solvBTC.BBN` 1:1,
   unwind through Avalon `repay(USDX) + withdraw(solvBTC.BBN)`,
   reconvert any residual collateral back to BTCB.
5. PnL = USD-denominated delta of
   `(solvBTC.BBN_at_expiry × spot − USDX_debt_at_expiry − swap costs)`.

Effective leverage at LTV=0.50, N=2: 1 + 0.5 + 0.25 = **1.75×**
collateral exposure.

## PnL math (5 BTC principal, 90-day horizon, BTC=$65k)
Indicative rates:
- Pendle PT-solvBTC.BBN implied APY: ~8.0 % (fixed, in BTC terms).
- Avalon USDX borrow APR net of incentives: ~1.5 %.
- Per-loop swap cost (USDX → USDT → BTCB → solvBTC.BBN, plus Pendle
  PT swap): ~15 bp on the borrowed leg.
- Levered collateral: 1.75×; net debt: 0.75×.
- Gross APY: 1.75 × 8.0 − 0.75 × 1.5 = 14.0 − 1.125 = **+12.88 %**.
- Net of swap drag (15 bp × 0.75 lev × 2 loops / 1 year ≈ 0.23 %):
  ~**+12.6 % APY**.
- 90-day net carry: 12.6 × 90/365 ≈ **+3.11 %** on principal.
- Dollar PnL: 5 BTC × $65k × 3.11 % ≈ **+$10,100**.

Gas: ~2 supply / borrow / multi-hop swap + Pendle interaction ≈ 2.0M
gas. ~$1.20.

## Block pinned
**47_500_000** (early-2025; assumed Pendle BSC PT-solvBTC.BBN listed and
Avalon Pendle adapter live). Re-pin.

## Addresses used
- `0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7` — solvBTC.
- `0x1346b81C8E3FE38d6cFc7e1B1cdF92C6b0050BFE` — solvBTC.BBN.
- `0xf9278C7c4aEfaC4dDfd0d496f7a1c39Ca6BcA6d4` — Avalon Lending Pool
  (`BSC.AVALON_LENDING_POOL`, TODO verify).
- `0x888888888889758F76e7103c6CbF23ABbF58F946` — Pendle Router V4 on BSC
  (`BSC.PENDLE_ROUTER_V4`, TODO verify cross-chain).
- `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` — PCS v3 SwapRouter.
- `LOCAL_USDX` — Avalon USDX, placeholder
  (`0xf3527eF8dE265eAa3716FB312c12847bFBA66Cef`); TODO verify.
- `LOCAL_PENDLE_MARKET_SOLVBBN` — Pendle PT/SY/YT market for
  solvBTC.BBN; placeholder (`0x00...B12041`). Resolve once Pendle
  publishes the BSC market address.
- `LOCAL_PT_SOLVBBN` — PT-solvBTC.BBN ERC20 (resolved via
  `IPendleMarket.readTokens()`).

## Risks
- **Pendle BSC PT-solvBTC.BBN may not exist at pinned block**: PoC
  guards Pendle market reads with try/catch; falls back to offline
  accounting if not live.
- **Avalon adapter for PTs not deployed**: many Aave V3 forks lack a
  Pendle PT oracle adapter at launch. If `supply(PT, …)` reverts, the
  strategy degrades to a single-shot PT hold (no recursive leverage),
  which still yields ~8 % APY × 90/365 = +1.97 % over the term.
- **PT depeg pre-expiry forced liquidation**: PTs can decouple from
  underlying mid-term during stress (sUSDe-style depeg events caused
  Pendle PTs to drop 15 %). At 1.75× leverage with 50 % LTV, a 15 %
  drop puts HF dangerously close to 1.0. Maintain ≥ 10 % HF headroom.
- **Pendle BSC router selector skew**: BSC deployment may use a
  different router address than mainnet; PoC sourcing the Pendle
  router from `BSC.PENDLE_ROUTER_V4` (already TODO verify).
- **PT-USDX oracle**: Avalon must price PT-solvBTC.BBN; if it uses the
  Pendle TWAP oracle, manipulation risk is low; if it uses spot AMM
  read, liquidation can be triggered by a flash-loan-driven price
  push.

## Result
Status: **theoretical** (BSC RPC not configured + multiple
TODO-verify addresses; PoC compiles, guards every external call with
try/catch, and falls back to offline accounting). Expected PnL:
**+2.5 – 3.5 % over 90 days on 5 BTC principal** at 1.75× effective
leverage on PT-solvBTC.BBN with Avalon USDX borrow rebated by the
protocol's incentive emission.
