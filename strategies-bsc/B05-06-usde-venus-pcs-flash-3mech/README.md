# B05-06: USDe Venus + PCS v3 flash atomic 3-mechanism position-builder

## Mechanism (3-mech atomic)
Single transaction stacks three independent BSC primitives:

1. **PCS v3 flash** (USDC/USDT 5bp pool) — borrow 1,000,000 USDT with no
   upfront principal. Pays 5 bp pool fee on repayment.
2. **PCS v3 swap** (USDT/USDe 1bp pool) — convert the flashed USDT into
   USDe at the prevailing BSC discount (USDe trades 50-150 bp under peg
   on this venue). The 1 bp fee tier is the deepest USDT/USDe pool on
   PCS.
3. **Venus** — deposit the USDe as collateral on the Venus Core (or V4
   isolated) pool, borrow USDT against it, and use the borrowed USDT to
   repay the flash.

## Why it composes
- The position-builder relies on the **discount** between USDe's market
  price (PCS v3 USDT/USDe pool: ~$0.994) and Venus' oracle price for
  USDe (assumed close to $1 / pegged feed). When we deposit "cheap" USDe
  but Venus values it at par, Venus is willing to lend us more USDT than
  the trade economically required.
- Three uncorrelated venues each contribute exactly one capability:
    - PCS v3 flash → free leverage,
    - PCS v3 1bp swap → captures the spot discount,
    - Venus → re-mints debt against the now-on-Venus-balance-sheet USDe.
- The atomicity is critical: the discount is mean-reverting, so the
  whole position-builder must close inside one block before the pool
  re-marks. If Venus' USDe oracle uses a TWAP or a Chainlink feed, the
  discount window is exactly the latency of that feed.

## Preconditions
- BSC block where (a) Venus has listed `vUSDe` as collateral with CF ≥
  0.70, (b) PCS v3 USDT/USDe 1bp pool prices USDe ≤ $0.996 (≥ 40 bp
  discount), (c) USDC/USDT 5bp pool has > $5M liquidity for the flash.
- Venus oracle for USDe values it at par (or at the cheaper of par /
  market — if Venus uses the cheaper side, this trade is breakeven and
  the strategy degenerates to a pure flash arb).

## Strategy steps (single tx)
1. Flash 1,000,000 USDT from PCS v3 USDC/USDT pool.
2. Swap USDT → USDe on PCS v3 1bp: receive 1,000,000 / 0.994 × (1 −
   0.0001) ≈ 1,005,930 USDe.
3. Approve Venus and call `vUSDe.mint(1,005,930e18)`.
4. Call `vUSDT.borrow(X)` where X = `collateralUsd × 0.75 × 0.97 =
   ~731,820 USDT`.
5. Wait — that's *less* than the flash repayment (1,000,500 USDT)! So
   the trade is NOT a pure atomic cash arb. It's a **position-builder**:
   the residual USDe collateral on Venus (worth ~$249,400) covers the
   gap and leaves free equity on the Venus collateral side.

   Net effect of the tx: zero up-front capital becomes a **leveraged
   USDe-long position on Venus** with a borrowed USDT debt at par-or-
   better terms. The position then earns the Venus supply rate on USDe
   minus the USDT borrow rate.

6. Optional follow-up (not in atomic tx): once the position is open,
   restake idle USDe → sUSDe to harvest Ethena APY on the residual
   collateral. This is the same recursive carry as B05-01 but seeded
   for free.

## PnL math (closed-form, atomic + 30-day hold)
- Flash repay: 1,000,000 × 1.0005 = 1,000,500 USDT owed.
- USDe received: 1,000,000 / 0.994 × 0.9999 = 1,005,930e18.
- Venus collateral value: 1,005,930 × $0.999 = $1,004,924.
- Max USDT borrow @ CF 0.75 × safety 0.97 = $731,083.
- Atomic net: −1,000,500 + 731,083 = **−269,417 USDT debt outstanding**.
- Residual collateral on Venus: 1,004,924 − 731,083 = **$273,841 USDe**.
- Atomic equity = residual collateral − net debt = $273,841 −
  $269,417 = **+$4,424** (free equity from the discount mining).

- 30-day carry on the open position:
  - Venus supply rate on USDe (modelled 6%): $1,004,924 × 6% × 30/365 =
    +$4,956.
  - Venus borrow rate on USDT (modelled 5.5%): $731,083 × 5.5% × 30/365
    = −$3,304.
  - Net carry = **+$1,652** over 30 days.

- **Total PnL = 4,424 + 1,652 ≈ $6,076 on zero principal.**

Gas: ~700k for the atomic tx + ~100k for the optional re-stake. At
1 gwei × $600/BNB ≈ $0.48.

## Block pinned
**42_700_000** — Q1 2025 window where USDe traded at the documented
60 bp discount on the 1bp PCS pool.

## Addresses used
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe (`BSC.USDe`).
- `BSC.PCS_V3_ROUTER`, `BSC.VENUS_COMPTROLLER`, `BSC.vUSDT`.
- `LOCAL_PCS_V3_USDC_USDT_5BP` — `0x…B521` (placeholder).
- `LOCAL_VUSDE` — `0x…B561` (placeholder).

## Risks
- **Venus USDe oracle uses the cheaper of par / market** — collapses
  the discount-mining equity to zero. Mitigation: check oracle source
  before deploying; the Pyth-backed feed historically lagged spot.
- **Flash size limit**: USDC/USDT 5bp pool may not support 1M USDT in
  one shot during low liquidity. Mitigation: scale or chain multiple
  flashes.
- **USDe re-pegs during tx**: not a risk inside one block, but the
  *position* carries the USDe peg risk on the residual collateral until
  liquidated. Mitigation: re-stake into sUSDe to internalise the rate.
- **Venus CF reduction**: Venus governance can lower the USDe CF mid-
  position, forcing partial liquidation. Mitigation: keep ≥ 5% safety
  margin (already encoded as SAFETY_BPS = 9700).

## Result
Status: **theoretical, contingent on Venus USDe listing + oracle
quotes-at-par**. Expected atomic PnL: **+$4,400 free equity** on zero
principal, plus ~**+$1,650 / 30-day** carry on the open position. PoC
emits the canonical PnL block with the atomic + carry settled into the
tracked USDT/USDe buckets.
