# F08-03: PT-sUSDe leveraged buy on Morpho with USDC flashloan

## Mechanism

Pendle's PT (Principal Token) for an underlying yield-bearing asset
trades at a discount to the underlying that compresses to zero at
maturity. For PT-sUSDe-26SEP2024, the trade is a **fixed-rate
cash-and-carry** on Ethena's funding-rate yield:

- Spot price of 1 PT-sUSDe at the fork block: ~`0.94 sUSDe` worth
  (depending on time-to-expiry and trailing funding).
- Maturity payout: exactly 1 sUSDe per PT (≈ $1.06 USDe equivalent
  because sUSDe NAV at maturity is ~$1.06).
- Implied fixed APY: ~14-18% annualised, observable on Pendle UI.

Looping PT-sUSDe against USDC debt converts that fixed yield into a
leveraged carry trade. The Morpho Blue `PT-sUSDe / USDC` 86% LLTV
market makes this scalable: post PT-sUSDe collateral, borrow USDC, the
borrow is at a variable Morpho rate (~7-9%), and the PT-sUSDe matures
deterministically into sUSDe, which can then be unstaked or sold.

Loop construction is a single-block **flashloop**:

```
flash USDC N from Morpho (free)
  -> swap (EQUITY + N) USDC -> USDe on Curve USDe/USDC
  -> Pendle.swapExactTokenForPt(USDe -> PT-sUSDe)
  -> Morpho.supplyCollateral(PT-sUSDe)
  -> Morpho.borrow(USDC, N)
  -> repay flash
```

With `EQUITY = 100k USDC` and `N = 400k USDC`, we end up with ~5x
notional PT-sUSDe collateralised against 400k USDC debt. Net exposure
is 500k of PT-sUSDe maturing into 500k+ sUSDe, minus 400k USDC debt
accruing interest until close.

## Why it composes

The four primitives stack as follows:

1. **Ethena sUSDe** — the underlying yield asset (delta-neutral perp
   funding). Provides the carry that PT discounts against.
2. **Pendle V4** — the PT is the *fixed-rate wrapper* around sUSDe.
   Pendle's AMM gives an atomic swap from USDe (or any token routed
   through SY) directly to PT.
3. **Morpho Blue** — provides both (a) the **0-fee flashloan** that
   bootstraps the leveraged position in one tx, and (b) the curated
   isolated **PT-sUSDe / USDC** market that accepts PT as collateral.
4. **Curve USDe/USDC** — the surrogate "USDC → USDe" conversion
   (since Ethena minting requires off-chain RFQ; same rationale as
   F08-01).

Crucially the entire setup happens in one block — no race risk that
PT-sUSDe re-prices between the swap and the supply. The borrow
amount exactly equals the flash principal, so no slippage on close.

## Preconditions

- Mainnet fork at a block where:
  - PT-sUSDe-26SEP2024 market is live on Pendle V4.
  - Morpho PT-sUSDe/USDC 86% LLTV market exists with USDC supply
    available > FLASH_USDC.
  - Curve USDe/USDC pool depth > 500k USDC at < 30 bps slippage.
- PT-sUSDe implied APY > Morpho USDC borrow APY (otherwise the
  leverage is loss-making).

## Strategy steps

1. Receive `EQUITY_USDC = 100_000e6` USDC via `deal()`.
2. `Morpho.flashLoan(USDC, FLASH_USDC=400_000e6)`.
3. In `onMorphoFlashLoan`:
   a. Curve: swap `500_000` USDC → ~`499_500e18` USDe (4-5 bps slippage).
   b. Pendle: `swapExactTokenForPt` USDe → PT-sUSDe. At a 0.94 PT/sUSDe
      ratio and the USDe/sUSDe deposit rate ~1.10, expect ~`483_000`
      PT-sUSDe out.
   c. `Morpho.supplyCollateral(PT-sUSDe, 483_000e18)`.
   d. `Morpho.borrow(USDC, FLASH_USDC=400_000e6)`.
4. Morpho settles the flash on callback return.
5. PoC reports the PT-sUSDe collateral and USDC debt deltas; the carry
   PnL realises as PT-sUSDe price drifts to par at maturity.

## PnL math

Let:
- `P` = PT/sUSDe price ratio at entry ≈ 0.94
- `r_f` = PT-sUSDe implied fixed APY ≈ 0.155
- `r_b` = Morpho USDC borrow APY ≈ 0.085
- `t` = time to maturity at entry ≈ 100 / 365 ≈ 0.274 yr
- `K` = realised leverage ≈ 5.0 (PT notional / equity)

Hold-to-maturity PnL on `100k` equity:

```
gross_pnl = K * EQUITY * r_f * t
          = 5 * 100_000 * 0.155 * 0.274
          ≈ 21_240 USD
borrow_cost = (K - 1) * EQUITY * r_b * t
            = 4 * 100_000 * 0.085 * 0.274
            ≈ 9_316 USD
net_pnl ≈ 21_240 - 9_316 ≈ 11_924 USD on 100k principal
        ≈ +11.9% over ~3.4 months ≈ +44% annualised
```

Curve swap + Pendle swap fees: ~10 bps total of 500k notional = $500.
Gas: ~800k gas × 30 gwei × $3k/ETH ≈ $72.

Net ≈ $11.35k cash-and-carry over the term.

If `r_b > r_f`, the trade is loss-making at leverage; the per-block
gate is `r_f > r_b`. PoC does not actively close-and-reopen; it
documents the entry shape.

## Block pinned

**19_950_000** (~Jun 17 2024). Verifications:

- PT-sUSDe-26SEP2024 active and deeply traded on Pendle V4 (TVL > $400M).
- Morpho `PT-sUSDe-26SEP/USDC` market exists with 86% LLTV.
- Trailing 30d sUSDe APY ≈ 12-16%.
- Morpho USDC borrow APY ≈ 7-9%.

## Risks

- **PT price gap-down (yield repricing)**: If sUSDe APY falls sharply
  before maturity, the PT mark-to-market drops and the Morpho oracle
  could push the position below LLTV → liquidation. Mitigation: 86%
  LLTV is conservative; the PoC sizes leverage at ~5x with > 3% buffer.
- **Funding-rate flip**: As in F08-01. PT price absorbs forward
  expectations, so an immediate flip causes a one-time PT mark down.
- **Pendle market dislocation**: Pendle AMM can quote unfavourable PT
  prices if liquidity drains (e.g. during expiry crunch). PoC uses
  `swapExactTokenForPt` with the default approx solver.
- **Morpho oracle / market admin**: PT-sUSDe Morpho oracle is custom
  to that PT/expiry; if the oracle is deprecated post-maturity the
  position must be closed before expiry.
- **Liquidity at unwind**: closing the position requires either
  (a) waiting for PT to mature (passive), then unstaking sUSDe with
  7d cooldown, OR (b) selling PT on Pendle into the same pool — which
  pays out USDe that must then be re-swapped for USDC. The slippage
  budget at unwind is the dominant variable for early-exit scenarios.
- **Smart-contract risk**: Pendle PT/YT/SY, Morpho singleton,
  Ethena sUSDe, Curve factory pool, plus the Pendle oracle adapter.
  Each is a distinct audit surface.

## Result

Status: theoretical (forge build not run; PT address, market id, and
oracle taken from Pendle/Morpho subgraph at fork block — verify).

Expected PnL: **~+11.9% over ~3.4 months** on 100k USDC equity at
realised ~5x leverage, gross of ~$500 swap fees and ~$72 gas.
Annualised ≈ +44%.
