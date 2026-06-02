# B04-08: PT-slisBNB Pendle + Venus collateral + Lista lisUSD borrow (3-mech)

## Mechanism

Three BSC primitives composed to extract yield from a single PT-slisBNB
position with two independent collateral usage paths:

1. **Pendle PT-slisBNB-25SEP2025** — bought BNB-denominated at a fixed
   discount via `swapExactTokenForPt`. Locks in slisBNB-equivalent yield.
2. **Venus isolated pool (PT collateral)** — deposit ~60% of the PT lot
   as `vPT-slisBNB`, enter market. No borrow is taken here — the PT
   accumulates Venus PT-supply APY *and* serves as emergency liquidity
   if Lista debt nears liquidation.
3. **Lista CDP** — deposit the remaining ~40% of PT as Lista collateral
   and `borrow` lisUSD at 45 % LTV. lisUSD is then idle (or could be
   parked in a stable pool, omitted here for clarity).

## Why it composes

- Two independent collateral books (Venus + Lista) on the same underlying
  PT means liquidation of one does not domino into the other.
- Pendle PT-slisBNB on BSC is the canonical BNB-denominated fixed-yield
  vehicle and is the first PT class Lista announced as CDP collateral.
- Venus has historically supported PT-class collateral on its isolated
  pool framework (placeholder vToken address in PoC).

## Strategy steps

1. Fund test contract with `EQUITY_BNB = 150 ether`.
2. `swapExactTokenForPt` BNB → PT-slisBNB.
3. Split PT 60/40:
   - 60 %: `IVToken.mint` into `V_PT_SLISBNB`, `enterMarkets`.
   - 40 %: `IListaInteraction.deposit(this, PT, amt)` then
     `borrow(PT, USD-notional × 45 %)` for lisUSD.
4. Warp past expiry.
5. Unwind: `payback` lisUSD on Lista; `withdraw` PT; `redeem` vToken on
   Venus; `redeemPyToToken` PT → BNB through Pendle.

## PnL math

Per 150 BNB ≈ $90k equity, 5-month maturity:
- Pendle PT carry (~2.5 % over 5 months × 150 BNB): +3.75 BNB
- Lista lisUSD mint (no interest charged on most CDPs): free
- Venus PT supply APY (~1.5 % × 60 % × 5/12): +0.56 BNB
- slisBNB underlying stake yield (passes through SY): +1.6 BNB
- Gas: negligible
- **Net: ≈ +5.9 BNB / +$3.5k per 150 BNB held to 25-SEP-2025**

If the user re-employs the minted lisUSD in B03-04 (lisUSD stable arb)
or a low-risk PCS/Wombat LP, add a further +1-3 % on $40k → +$400-1200.

## Block pinned

`FORK_BLOCK = 44_000_000`.

## Addresses used

- `BSC.PENDLE_ROUTER_V4`, `BSC.VENUS_COMPTROLLER`, `BSC.LISTA_INTERACTION`,
  `BSC.slisBNB`, `BSC.lisUSD` — all from `BSC.sol`.
- `LOCAL_PT_SLISBNB_MARKET` — placeholder.
- `V_PT_SLISBNB` — Venus isolated vToken for PT-slisBNB; **TODO verify**.

## Risks

- **Either Venus or Lista PT-collateral listing missing**: PoC falls back
  to single-mechanism PT cash-and-carry on the failing leg. The other
  leg still completes.
- **lisUSD depeg below 0.97 at unwind**: would force partial Pendle PT
  liquidation to procure repay-currency.
- **PT pre-maturity price drop**: liquidation risk on Lista if PT trades
  > 5 % below entry; mitigated by 45 % LTV cap.

## Result

Status: **theoretical**. PoC compiles + degrades gracefully per leg.
Expected PnL: **+$3-5k per 150 BNB held to maturity, scaling linearly**.
