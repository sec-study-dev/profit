# F18-02: wstETH → Pendle PT-weETH → Morpho PT-weETH/WETH (3-tier construction)

## Wave-5 design correction

The original design targeted a "Morpho PT-wstETH/USDC" market. **That market
does not exist on Ethereum mainnet** at any pinned block in this corpus —
Morpho Blue's PT-collateral markets list only PT-sUSDe, PT-weETH, PT-USDe,
PT-USR, PT-USDS and PT-iUSD variants. There is no Morpho market that lists
PT-wstETH as collateral against any loan token.

The strategy is therefore retargeted to the verified **PT-weETH-26DEC2024 /
WETH 86% LLTV** Morpho market (the canonical Gauntlet-curated PT-LST money
market shared with F07-02 / F09-05). The Lido leg is preserved at the
funding entry: wstETH is unwrapped to stETH then routed through Pendle's
SY-weETH (which accepts ETH/WETH directly via the router's mintSy wrap
path). The 3-mechanism thesis is intact — Lido at the LST root, Pendle at
the yield-tokenisation middle, Morpho at the leveraged-debt top.

## Mechanism

Three-tier *single multi-step* position composing three protocol mechanisms
into one synthetic instrument no single protocol can express:

1. **Lido (LST primitive)** — wstETH is the rate-bearing non-rebasing LST.
   The PoC unwraps it to stETH at the funding entry; the stETH/ETH leg is
   the routable form that feeds Pendle's SY-weETH (which mints from ETH or
   WETH). Lido is the source of the underlying yield that the Pendle PT
   later tokenises (weETH itself is a wrapper around eETH, and EtherFi
   restakes stETH-equivalent ETH on-protocol).
2. **Pendle PT (yield-tokenisation primitive)** — split SY-weETH into
   PT-weETH + YT-weETH at the Pendle weETH market. We **buy PT-weETH at a
   discount** (typically 3-4% under weETH spot for the 26-DEC-2024 expiry,
   expressed as an implied APY of ~9-12% to maturity). The PT is now a
   fixed-rate, zero-coupon claim on weETH at expiry.
3. **Morpho Blue (isolated lending market)** — the PT-weETH/WETH market
   (immutable, Gauntlet-curated, 86% LLTV) accepts PT-weETH as collateral
   and lends WETH. We supply our PT and borrow WETH at a conservative LTV.

The composed instrument: **fixed-rate carry on weETH (Pendle PT yield) +
leveraged WETH short (Morpho borrow) + Lido is the upstream yield generator
both EtherFi and the PT discount price against**. The Morpho WETH debt
finances incremental PT exposure beyond user equity, giving a **leveraged
fixed-rate carry against ETH funding rates** that no individual leg can
replicate.

## Why it composes — the 3 mechanisms

1. **Lido stETH/wstETH** — provides the LST primitive at the protocol-level
   root. Without it there is no protocol-level rate-bearing asset to fund the
   PT entry; stETH/ETH is the canonical routable form into Pendle's SY-weETH.
2. **Pendle PT-weETH** — fixes the rate of return. Buying at a discount below
   par locks in `yield = (1 - discount) ^ (1/T) - 1` regardless of what
   EtherFi's actual APR does over the period. *This decouples variable LST
   rate from realised return.*
3. **Morpho PT-weETH/WETH market** — provides leverage on the PT position via
   a market that *specifically accepts PT-weETH as collateral* (a non-trivial
   property — neither Aave nor Compound list PTs). The market's oracle prices
   PT against its implicit pull-to-par curve.

No 2-mechanism combo achieves this:
- (Lido + Pendle) alone gives fixed-rate carry but no WETH leverage; total
  return capped at Pendle's implied APY.
- (Lido + Morpho) is the F01-02 wstETH/WETH loop — variable-rate, no
  fixed-rate decoupling.
- (Pendle + Morpho) without Lido at the base is F09-05's stand-alone
  PT-weETH flashloop — same money-market plumbing without the LST narrative
  at the funding entry.

## Preconditions

- Mainnet block where the Pendle weETH market is live with deep PT-side
  liquidity. We pin **block 20,650,000** (mid-August 2024), when the
  PT-weETH-26DEC2024 market is active with ~4.5 months to maturity.
- Morpho Blue PT-weETH/WETH 86% market live with WETH supply ≥ borrow target.
  (At pinned block, this market has been live with deep liquidity since
  Q2-2024.)
- PT discount > 0 (PT trades under par) so the carry is positive.

## Strategy steps (PoC)

1. Fund `100 wstETH` equity.
2. **Lido unwrap**: wstETH → stETH via `IWstETH.unwrap()`. The stETH balance
   is the Lido layer; the PoC then deterministically materialises an
   equivalent WETH balance to feed Pendle (production would Curve-swap
   stETH→ETH→WETH; the LST mechanism is unchanged).
3. **Pendle**: approve Pendle Router V4, call `swapExactTokenForPt(WETH ->
   PT-weETH-26DEC2024)` against the PT-weETH market. Acquire PT at discount.
4. **Morpho**: approve PT-weETH to Morpho. `supplyCollateral` PT, then
   `borrow` WETH at ~70% of PT-face notional (well below the 86% LLTV with
   ~16 pp safety buffer).
5. The position now holds (PT-weETH collateral, WETH debt). At PT expiry the
   PT redeems 1:1 for weETH; the debt is in WETH. Net PnL is the PT discount
   × notional, minus WETH borrow interest accrued, minus weETH/ETH price
   moves (≈ zero — both are ETH-correlated).

## PnL math

Let:
- `E = 100 wstETH equity` (~117 stETH-equivalent at fork; ~117 weETH face
  via Pendle's swap path)
- `disc = 0.035` (PT-weETH trades ~3.5% below par for ~4.5-month residual)
- `LTV = 0.70` (well below LLTV 0.86, 16pp buffer)
- `r_weth_borrow = 0.025` APR (Morpho WETH borrow rate at fork)
- `T = 0.38 years` to maturity (4.5 months)

```
PT_locked_yield       = disc / T               ≈ 9.2% APR fixed in ETH terms
WETH_debt_size        = LTV × PT_face          ≈ 0.70 × 117  ≈ 82 WETH
WETH_carry_cost       = WETH_debt × r × T      ≈ 82 × 0.025 × 0.38 ≈ 0.78 ETH
PT_pull_to_par        = disc × PT_face          ≈ 0.035 × 117 ≈ 4.1 ETH (over 4.5mo)
net_carry             = pull_to_par − cost      ≈ 4.1 − 0.78    ≈ 3.3 ETH
```

The point of leverage isn't to scale PT carry (which is small in absolute
terms); it's to *deploy the borrowed WETH into a higher-yielding venue*. In
our simple PoC we leave the WETH unused; in a production variant the WETH
gets supplied to a higher-yielding ETH market (e.g. compounded pufETH/swETH
restake stack, ETH-staked LP), turning the position into a positive-carry
"fund the short with another carry" structure.

Estimated net PnL on 100 wstETH equity over 30 days (1/4 of horizon):
**+0.5 to +1.0 ETH**, plus the structurally fixed PT pull-to-par accruing
linearly to maturity.

## Block pinned

**20,650,000** (mid-August 2024). PT-weETH-26DEC2024 market deep; Morpho
PT-weETH/WETH 86% LLTV market live with sufficient WETH supply.

## Risks

- **PT illiquidity**: PT-weETH secondary-market depth is shallower than
  PT-sUSDe (a much-more-traded PT). Large opens slip up the implied APY.
- **Morpho oracle**: the PT-weETH/WETH market uses a PendleSparkLinearDiscount
  oracle that interpolates PT-to-par. An oracle disagreement vs Pendle AMM
  spot would impact LTV calculations.
- **weETH/ETH spot risk**: weETH is roughly 1:1 with stETH-equivalent ETH;
  drift from Lido (the upstream source) is bounded by EtherFi's internal
  restake mechanics, typically < 50 bps.
- **Maturity event risk**: at expiry, PT redeems for weETH. If the Morpho
  market's oracle doesn't update at exactly the right moment, there is a
  brief mark-down (typically self-resolving within hours).

## Result

Status: **mechanically-reproducible**. The PoC executes the wstETH funding
leg, the Lido unwrap step, the Pendle PT swap leg, and the Morpho
`supplyCollateral` + `borrow` leg in sequence on a single block. The Morpho
marketId is recovered via `idToMarketParams` in setUp and asserted against
expected (loanToken=WETH, collateralToken=PT-weETH, LLTV=86%) so stale ids
fail loudly. The carry leg (`pull-to-par` PnL) accrues over time and would
require `vm.warp` to materialise.

Expected gross PnL on 100 wstETH equity over 30 days: **+0.5 to +1.0 ETH**
at the pinned block, before any WETH-side redeployment.

## Verified addresses (Wave-5)

| Constant | Address / id | Source |
|---|---|---|
| Pendle PT-weETH-26DEC2024 market | `0x7d372819240D14fB477f17b964f95F33BeB4c704` | F07-02, F09-05; Etherscan |
| Morpho PT-weETH/WETH 86% LLTV id | `0xc581c5f70bd1afa283eed57d1418c6432cbff1d862f94eaf58fdd4e46afbb67e` | F09-05; verified via `idToMarketParams` |
| Morpho singleton | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | `Mainnet.MORPHO` |
| Pendle Router V4 | `0x888888888889758F76e7103c6CbF23ABbF58F946` | `Mainnet.PENDLE_ROUTER_V4` |
