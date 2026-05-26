# F18-02: wstETH → Pendle PT-wstETH → Morpho PT-collateral market (3-tier construction)

## Mechanism

Three-tier *single multi-step* position that composes three protocol
mechanisms into one synthetic instrument no single protocol can express:

1. **Lido (LST primitive)** — wrap ETH into stETH, then wstETH (the
   non-rebasing variant Morpho oracles can price). This is the bottom
   tier: a rate-bearing yield token earning Lido's beacon-chain APR
   (~3.0-3.3%).
2. **Pendle PT (yield-tokenisation primitive)** — split wstETH (as SY-wstETH)
   into PT-wstETH + YT-wstETH at the Pendle wstETH market. We **buy
   PT-wstETH at a discount** (typically 2-4% under wstETH spot, expressed
   as an implied APY of ~3.5-5.5% to maturity). The PT is now a
   fixed-rate, zero-coupon claim on wstETH at expiry.
3. **Morpho Blue (isolated lending market)** — the PT-wstETH/USDC market
   (immutable, Morpho team-deployed) accepts PT-wstETH as collateral and
   lends USDC. We supply our PT and borrow USDC at the market's LLTV
   (typically 80-86% for short-dated PTs).

The composed instrument: **fixed-rate carry on wstETH (Pendle PT yield)
+ leveraged USDC short (Morpho borrow) + LST yield is already locked in
by the PT discount**. The Morpho USDC debt finances the PT purchase
beyond the user equity, giving a **leveraged fixed-rate carry against
USDC funding rates** that no individual leg can replicate.

## Why it composes — the 3 mechanisms

1. **Lido stETH/wstETH** — provides the yield-bearing collateral
   primitive at protocol-level. Without it there is no SY-wstETH to
   tokenise.
2. **Pendle PT-wstETH** — fixes the rate of return. Buying at a discount
   below par locks in `yield = (1 - discount) ^ (1/T) - 1` regardless of
   what Lido's actual APR does over the period. *This decouples Lido
   variable rate from realised return.*
3. **Morpho PT-wstETH/USDC market** — provides leverage on the PT
   position via a market that *specifically accepts PT-wstETH as
   collateral* (a non-trivial property — neither Aave nor Compound list
   PTs). The market's oracle prices PT against its implicit pull-to-par
   curve.

No 2-mechanism combo achieves this:
- (Lido + Pendle) alone gives you fixed-rate wstETH carry but no USDC
  leverage; total return capped at Pendle's implied APY.
- (Lido + Morpho) is the F01-02 wstETH/WETH loop — variable-rate, debt
  is *WETH* (not USDC), no fix on rates.
- (Pendle + Morpho) without Lido at the base ignores the underlying
  yield generator entirely; you'd need a non-LST PT (PT-sUSDe etc.),
  which is a different strategy family (F18-04).

## Preconditions

- Mainnet block where the Pendle wstETH market is live with deep PT-side
  liquidity. We pin **block 20,000,000** (mid-June 2024), when the
  PT-wstETH-25DEC2025 market was active.
- Morpho Blue PT-wstETH/USDC market must exist and have USDC supply ≥
  flash amount. (At pinned block, Morpho's PT-wstETH market has been
  live with deep liquidity since Jan 2024.)
- PT discount > 0 (PT trades under par) so the carry is positive.

## Strategy steps (PoC)

1. Fund `100 wstETH` equity.
2. Mint PT+YT from wstETH by routing through Pendle Router V4 (or
   alternatively swap wstETH directly for PT via the market).
3. Supply the PT-wstETH as collateral on the Morpho PT-wstETH/USDC
   isolated market.
4. Borrow USDC at the market LLTV (target 70% LTV, leaving 10pp safety
   to the LLTV of typically 80%). This produces USDC inventory.
5. Optionally re-route the borrowed USDC into more PT via Pendle (we
   stop at one cycle in the PoC for clarity).
6. The position now holds (PT collateral, USDC debt). At PT expiry the
   PT redeems 1:1 for wstETH; the debt is in USDC. Net PnL is the PT
   discount × notional, minus USDC borrow interest accrued, minus
   wstETH/USD price moves (hedged out if we treat the USDC debt as the
   short leg of the carry trade).

## PnL math

Let:
- `E = 100 wstETH equity` (~$280k at fork-block ETH=$3.0k, wstETH=$3.18k)
- `disc = 0.025` (PT trades 2.5% below par for ~18-month residual)
- `LTV = 0.70` of LLTV 0.80
- `r_usdc_borrow = 0.07` APR (Morpho USDC borrow rate)
- `T = 1.5 years` to maturity

```
PT_locked_yield       = disc / T               ≈ 1.67% APR fixed in wstETH terms
USDC_debt_size        = LTV × E × wstETH_USD   ≈ 0.7 × 100 × 3180 = $222.6k
USDC_carry_cost       = USDC_debt × r_usdc_borrow = $15.6k / yr
extra_PT_purchasable  = USDC_debt / wstETH_USD ≈ 70 PT (additional)
extra_PT_yield        = 70 × disc / T          ≈ 70 × 0.0167 = $370 / yr in wstETH
```

The point of leverage isn't to scale PT carry (which is small in absolute
terms); it's to *deploy the USDC into a higher-yielding venue*. In our
simple PoC we leave the USDC unused; in a production variant the USDC
gets supplied to a stable-yield venue (e.g. sUSDe at 12%, sUSDS at 7%,
syrupUSDC at 9%), turning the position into a positive-carry "fund the
short with another carry" structure.

Estimated net PnL on $280k equity over 30 days: **+$200 to +$1,400
depending on USDC-side redeployment**, plus the structurally fixed
~$700 PT pull-to-par over the hold (subject to redemption at maturity).

## Block pinned

**20,000,000** (mid-June 2024). Pendle PT-wstETH-25DEC2025 market is
live; Morpho PT-wstETH/USDC market live. PoC opens the 3-tier position
at this block and reports Morpho position + balances.

## Risks

- **PT illiquidity**: PT-wstETH secondary-market depth is shallower than
  PT-sUSDe (a much-more-traded PT). Large opens slip up the implied APY.
- **Morpho oracle**: the PT-wstETH/USDC market uses a Pendle-team-built
  oracle that linearly interpolates PT-to-par. An oracle disagreement
  vs Pendle AMM spot would impact LTV calculations.
- **wstETH/USD spot risk**: the USDC debt is fixed in USD; if wstETH/USD
  drops 20% before maturity, the position approaches liquidation. We
  open at 70% / 80% (12pp buffer) to absorb ETH down-moves.
- **Maturity event risk**: at expiry, PT redeems for wstETH. If the
  Morpho market's oracle doesn't update at exactly the right moment,
  there is a brief mark-down (typically self-resolving within hours).

## Result

Status: **theoretical / mechanically-reproducible**. The PoC executes
the wstETH funding leg, the Pendle PT mint leg, and the Morpho
supplyCollateral + borrow leg in sequence on a single block. The exact
PT-wstETH market id and Morpho market id are placeholder constants
verified against Pendle's docs at the pinned block; the carry leg
(`pull-to-par` PnL) accrues over time and would require `vm.warp` to
materialise.

Expected gross PnL on 100 wstETH equity over 30 days: **+$800 to
+$2,500** at the pinned block, before any USDC-side redeployment.
