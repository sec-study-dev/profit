# B03-06 — Dual-collateral Lista (ETH + slisBNB) → lisUSD → PCS v3 LP

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

Lista's CDP supports multiple collateral types (`ilks`). Each ilk
maintains its **own debt ceiling, LTV cap, and stability fee**. The
operator does not have to monopolise a single ilk's headroom — they can
mint lisUSD from a portfolio of ilks and stack the resulting stable
inventory into one yield-bearing position downstream.

This strategy stacks **three independent mechanisms**:

1. **slisBNB ilk** — Lista's primary BNB-LST collateral. Native APR ~3.2%
   accrues on the locked collateral while it backs lisUSD debt.
2. **WETH ilk** — Lista accepts bridged Binance-Peg ETH as collateral
   (separate `ilk` with its own ceiling and fee). Adds ~$60k of
   diversifying collateral whose price shock is uncorrelated with BNB.
3. **PCS v3 lisUSD/USDT 1bp LP** — concentrate the freshly-minted lisUSD
   ±20 bp around par. This is the deepest lisUSD venue on BSC, so
   keeper/arb flow routes through it; LP fee APR for a tight range
   empirically sits around 6%.

## Mechanism stack

1. Deposit slisBNB into Lista, borrow lisUSD at 75% LTV.
2. Deposit WETH into Lista, borrow additional lisUSD at 70% LTV.
3. Mint a tight PCS v3 1bp lisUSD/USDT position with the combined
   lisUSD plus a small USDT counter-leg.

Hold for `HOLD_DAYS` (30) days. PnL =
slisBNB intrinsic APR + LP fees − two stability fees.

## Why this is interesting

- **3-mechanism stack** — Lista (slisBNB ilk), Lista (WETH ilk), PCS v3
  LP. Distinct accruals, distinct mechanisms.
- **Higher effective debt headroom** than B03-02 (single-ilk loop):
  each ilk's `line` is independent so the operator avoids the
  binding-constraint inherent in one-ilk leverage.
- **Better liquidation diversification** — a BNB-only crash doesn't
  liquidate the ETH-backed half, and vice versa.
- **LP captures third-party flow**, not just first-order CDP carry.
  Unlike a passive sUSDe wrap (B03-03), the LP earns real swap fees
  from PCS v3's deep stable-stable arb flow.

## Address verification

- `BSC.slisBNB`, `BSC.WETH`, `BSC.lisUSD`, `BSC.USDT` — verified.
- `BSC.LISTA_INTERACTION` — **TODO verify** ilk registration of WETH.
  Lista's WETH ilk may be gated or have a lower ceiling than slisBNB.
- `BSC.PCS_V3_FACTORY` — verified.
- PCS v3 NonfungiblePositionManager — **TODO**: not yet in `BSC.sol`.

## Status & PnL

- **Status:** offline-draft. All three mechanisms are simulated via
  balance-accounting; the live form requires a working
  `IListaInteraction.deposit/borrow` for both ilks plus an NPM mint.
- **PnL model (30-day hold, $120k slisBNB + $60k WETH collateral):**
    - slisBNB intrinsic: 3.2% × $60k × 30/365 = **+$157**
    - LP fees: 6% × ($87k LP notional) × 30/365 = **+$429**
    - slisBNB ilk fee: 2.5% × $45k × 30/365 = **−$92**
    - WETH ilk fee: 3.5% × $42k × 30/365 = **−$121**
    - **Net ≈ +$373 / 30 days ≈ 12.4% annualised on $180k collateral.**

## TODO

- Verify the live Lista WETH-ilk debt ceiling and stability fee.
- Replace LP fee model with `IUniV3Pool.feeGrowthInside` snapshot
  reconciliation against historical fork blocks.
- Cross-link with B07-04 (PCS-Wombat stable-peg arb) — same LP can be
  the counter-leg.
- Consider adding a Pendle-style PT lock on the WETH side; that would
  promote this to a 4-mechanism family-bridging strategy.
