# F04-08: sDAI -> Spark -> USDC borrow -> Curve 3pool recycle

## Mechanism

Three-mechanism stack that re-uses the F04-02 chassis but rotates the borrow
asset from DAI to USDC:

1. **sDAI** — Maker's DSR-bearing ERC-4626. Collateral.
2. **Spark Pool** — Aave v3 fork. The interest-rate strategies for DAI and
   USDC are **distinct**: DAI uses the Maker-aligned DAI-IRM
   (`borrow ≈ DSR + spread`), while USDC uses a standard 2-slope kinked IRM
   parameterised by SparkLend governance independently of DSR.
3. **Curve 3pool** — Swaps the borrowed USDC back to DAI so it can re-enter
   sDAI on the next iteration.

When Spark's USDC utilisation is below the kink, the USDC variable borrow APY
sits materially **below** the DAI variable borrow APY. At that moment the
loop's effective borrow cost is the USDC rate (plus ~1-3 bps Curve slip per
hop) — *not* the DAI rate that's pinned just above DSR by Maker
governance. The net APY:

```
APY_net = L * DSR_APY - (L - 1) * Spark_USDC_borrow_APY - 2 * L * curve_slip
```

vs F04-02:
```
APY_net = L * DSR_APY - (L - 1) * Spark_DAI_borrow_APY
```

The trade is positive when `Spark_DAI_borrow - Spark_USDC_borrow > 2 * curve_slip`.
At the pinned block (block 19_500_000, March 2024) Spark USDC borrow APY was
~6% versus Spark DAI borrow APY ~14.5% — an 8 pp gap that more than pays for
the Curve cost.

## Why it composes

Same-family-only:
- sDAI is the canonical DSR collateral.
- Spark exposes a USDC market with an IRM Maker governance does **not** pin
  to DSR; this is the *only* place where you can pay sub-DSR rates on debt
  backed by DSR-bearing collateral.
- Curve 3pool is the natural USDC<->DAI rail with sub-3 bp slip on 200k
  notionals.

The combination is unique because Aave v3 doesn't list sDAI (only a 2023
proposal); Morpho doesn't have a Spark-equivalent USDC rate model; and
Spark's USDC reserve is governance-blessed (no need to permission-create a
market).

## Preconditions

- `Spark_DAI_borrow_RAY > Spark_USDC_borrow_RAY + curve_slip_RAY_equivalent`.
  PoC logs both for empirical validation. If the gap is non-positive at the
  pinned block the loop bleeds; the assertion bounds the worst case at 2%
  of seed.
- 3pool USDC/DAI ratio within 50 bps of 1.0 (otherwise the slippage guard
  trips and the iteration breaks early).
- sDAI is listed on Spark (true since 2023) and the USDC reserve is
  borrowable (true at all blocks after Spark's Q4 2023 spell).

## Strategy steps

1. Pin to `19_500_000`. Snapshot DSR, DAI-borrow, USDC-borrow rates.
2. Seed 200k DAI. Convert to sDAI. Supply to Spark.
3. Loop 5x:
   - Read `availableBorrowsBase` (USD-e8).
   - `borrowUsdc = availBase * SAFE_FRAC / 1e20` (USD-e8 -> USDC-e6).
   - `Spark.borrow(USDC, borrowUsdc, variable, 0, this)`.
   - `Curve.exchange(USDC -> DAI, borrowUsdc, min_dy = 99.5% of nominal)`.
   - `sDAI.deposit(daiOut)`. `Spark.supply(sDAI, shares)`.
4. Warp 30 days. `pot.drip()`.
5. Unwind: withdraw sDAI -> redeem to DAI -> Curve DAI->USDC -> repay USDC.
6. Pull residual collateral; consolidate any leftover USDC to DAI.

## PnL math

Let `r_s = DSR APY = 15%`, `r_u = Spark USDC borrow = 6%`, `L = 2.6x`,
`curve_slip = 0.03%`.

```
APY_net = 2.6 * 0.15 - 1.6 * 0.06 - 5.2 * 0.0003
        = 0.39 - 0.096 - 0.00156
        = 0.2924 = 29.24% on equity
```

vs naked sDAI at 15%. Over 30 days on $200k seed:
```
gain = 200_000 * ((1.2924)^(30/365) - 1) ≈ 200_000 * 0.02124 ≈ $4_248
```

Gas: 5-iter loop with Curve hop is ~2.2 M gas. At 20 gwei / ETH=$3900: ~$172.
Net ≈ $4_076.

When the rate gap shrinks (post-Q2 2024, Spark normalised USDC rates closer
to DAI), the edge collapses to single-digit bps and F04-02 dominates again.

## Block pinned

`19_500_000` — March 6 2024. DSR at 15%, Spark DAI borrow ~14.5%, Spark USDC
borrow ~6% (USDC utilisation on Spark was very low at that point because
USDC suppliers had not yet rotated to Spark). 8 pp rate gap is enormous.

## Risks

- **3pool depeg.** Routing USDC<->DAI through 3pool is exposed to USDC
  depeg. PoC guards every swap at 99.5% of nominal; a SVB-style USDC depeg
  would short-circuit iterations before bleeding seed.
- **USDC rate convergence.** Spark governance can re-parameterise the USDC
  IRM at any spell. If `r_u` rises to meet `r_d` the loop reverts to F04-02
  economics minus the Curve drag — strictly worse.
- **Borrow cap reached.** Spark's USDC borrow cap can fill (especially at low
  rates). PoC breaks the loop early on `availBase == 0`.
- **Curve LP withdrawal squeeze.** A large LP exit from 3pool changes the
  effective swap rate. 1-2% intraday move is possible; the slippage guard
  catches it.

## Result
Status: theoretical-historical-replay
Expected PnL: ~29.24% APY on equity (~$4,076 net per $200k seed over 30 days at DSR=15%, Spark USDC borrow=6%, L=2.6x)

A 3-mechanism (sDAI + Spark + Curve 3pool) loop that wins when the borrow
asset is rotated from DAI to USDC at moments of large inter-asset rate gaps on
Spark. PoC asserts leverage > 2.2x, no underwater state, post-unwind DAI
within 2% of seed in worst case, with a clear ~29% on-equity APY at the
pinned block.
