# B04-05: PT-asBNB BSC + Venus collateral + USDT borrow (3-mechanism)

## Mechanism

Three independent BSC primitives stacked into a single PnL surface:

1. **Astherus (asBNB)** — embedded restaking yield. asBNB is a non-rebasing
   share token whose `convertToAssets` increases over time as Astherus
   accumulates BNB restaking rewards.
2. **Pendle PT-asBNB-25SEP2025** — buy the PT at a fixed BNB-denominated
   discount through `swapExactTokenForPt`. Holding to maturity locks in
   the fixed APY independent of subsequent restaking-rate moves.
3. **Venus isolated pool** — use PT-asBNB (or SY-asBNB) as collateral and
   borrow USDT against it. The borrow APY (typically 4-6 %) is paid in
   USDT but the collateral accrues BNB-denominated yield, plus the Pendle
   PT carries the front-loaded discount.

## Why it composes

- All three primitives live on BSC, no bridges.
- Pendle SY-asBNB wraps Astherus's asBNB without unwrapping; so Pendle
  positions still capture every Astherus airdrop/point distribution.
- Venus has been onboarding PT collateral on isolated pools (mirrors what
  Aave/Morpho do on mainnet); if listed, an LTV in the 50-60% range is
  typical.

## Strategy steps

1. Fund test contract with `EQUITY_BNB = 200 ether`.
2. `swapExactTokenForPt` BNB → PT-asBNB on Pendle V4 router.
3. Approve `V_PT_ASBNB` (Venus vToken for PT collateral) and call `mint`.
4. `enterMarkets([V_PT_ASBNB])` on Venus Comptroller.
5. `borrow(targetUSDT)` from `vUSDT` at 50 % LTV of PT collateral USD value.
6. Warp past `expiry`.
7. `repayBorrow(max)` on vUSDT; `redeem` PT back from vToken.
8. `redeemPyToToken(...)` PT → BNB through Pendle router.
9. PnL = `final_bnb - equity_bnb`, plus the recycled USDT can be re-routed
   to a second PT-asBNB position for true 2x leverage (not implemented in
   the PoC for clarity).

## PnL math

Per 200 BNB equity (~ $120k):
- Pendle PT fixed yield (3-month carry): ~3.5 % annualized × 0.25 = +0.875 % = +1.75 BNB
- Astherus restake yield captured in asBNB exchange-rate appreciation:
  +1.5 % over 3 months = +3 BNB (passes through PT.SY redemption)
- Venus USDT borrow cost: $36k borrowed @ 5 % × 0.25 = -$450 ≈ -0.75 BNB
- Gas: negligible on BSC (~$1)
- Net: **+4-6 BNB / +$2,400 - $3,600 per 200 BNB held to 25-SEP-2025**.

## Block pinned

`FORK_BLOCK = 44_500_000` — mid-Q2 2025, ~3 months before the assumed
25-SEP-2025 expiry.

## Addresses used

- `BSC.PENDLE_ROUTER_V4` = `0x888888888889758F76e7103c6CbF23ABbF58F946`
- `BSC.asBNB` = `0x77734e70b6E88b4d82fE632a168EDf6e700912b6`
- `BSC.VENUS_COMPTROLLER` = `0xfD36E2c2a6789Db23113685031d7F16329158384`
- `BSC.vUSDT` = `0xfD5840Cd36d94D7229439859C0112a4185BC0255`
- `LOCAL_PT_ASBNB_MARKET_25SEP2025` — placeholder
- `V_PT_ASBNB` — placeholder; **TODO verify** once Venus lists PT-asBNB
  collateral on an isolated pool.

## Risks

- **Venus PT collateral not yet listed**: PoC degrades the borrow leg to a
  no-op; the underlying Pendle cash-and-carry still works on its own.
- **asBNB depeg**: short-term liquidity is thin; if asBNB trades below NAV
  at maturity the SY-redemption step has basis risk.
- **Liquidation if BNB rallies hard against USDT borrow**: the loan is
  USDT-denominated, collateral is BNB-denominated. A 50 % BNB rally
  doubles the effective LTV in USD terms but actually reduces it in
  collateral terms — risk is BNB *crash*, not rally.

## Result

Status: **theoretical** (Venus PT listing pending). PoC compiles + degrades
gracefully. Expected PnL: **+$2,400-$3,600 per 200 BNB held 3 months**.
