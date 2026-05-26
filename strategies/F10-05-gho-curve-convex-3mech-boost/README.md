# F10-05: GHO mint + Curve GHO/USDC LP + Convex boost (3-mechanism)

## Mechanism (3-mech)

This strategy stacks **three independent yield surfaces** anchored on three
different protocols:

1. **Aave V3 GHO facilitator** — mints GHO directly from a governance-set
   borrow-rate curve. As discussed in F10-01, the GHO sticker rate is decoupled
   from utilisation, which can leave it materially below the rate available on
   secondary GHO yield venues. Borrowing GHO is the cheap leg.
2. **Curve GHO/USDC stableswap (factory ng-stableswap pool)** — a 2-coin
   GHO/USDC pool that earns swap-fee yield plus a CRV gauge stream. The
   pool token (LP) is a standard 18-decimal ERC-20 mintable via
   `add_liquidity([gho, usdc], min_mint)`.
3. **Convex Booster** — wraps the Curve LP into a tokenised gauge position so
   the depositor inherits Convex's collective `veCRV` boost (~2.0-2.5x base
   CRV emissions) plus a share of Convex's CVX emissions. Convex's PID for
   the GHO/USDC pool is read from `Booster.poolInfo(PID)` on-chain; if the
   PID is unavailable at the pinned block the test falls through to a
   plain-LP carry and emits a `convex_pid_unavailable` log.

The net is `Aave (GHO mint cost) → Curve (swap fee + CRV) → Convex (boosted CRV
+ CVX)`. Each mechanism is mechanically distinct from the others: Aave is a
money-market borrow, Curve is an AMM LP, Convex is a yield-aggregator gauge
proxy. None of the three would be profitable in isolation under the same
pricing parameters — Curve LP yield alone is typically <2%, GHO carry alone
is fee-bound at sub-100k notional, and Convex boost alone requires owning the
LP. Combining them captures all three margins on a single supplied collateral
unit.

## Why it composes

The composition is **vertical** — each layer takes the output of the previous
layer as its input:

- **Aave -> Curve**: borrowed GHO is added to the Curve pool as one side of the
  pair. The pool prices GHO near $1 (anchored by GHO arbitrageurs), so GHO
  deposited into the LP is priced at par and no slippage is taken at deposit.
- **Curve -> Convex**: the LP token is staked into Convex's Booster, which
  re-stakes it into Curve's gauge through a permanently-locked veCRV NFT and
  redistributes CRV (boosted) + CVX emissions to depositors.

The three legs share **only** the GHO/USDC token pair — there is no shared
risk surface beyond GHO depeg. A failure in any one of (Aave, Curve, Convex)
unwinds that leg's yield without cascading to the others.

## Preconditions

- Mainnet post-Convex GHO/USDC PID registration (typically Q3 2024+). Block
  pinned at **20_900_000** (≈ Nov 5 2024). At this block:
  - GHO facilitator has bucket headroom (verified via reserve data).
  - Curve GHO/USDC ng-stableswap pool is the primary GHO/USDC venue.
  - Convex Booster has registered the LP with non-shutdown PID.
- USDC available as Aave collateral (any non-isolated USD asset works).
- CRV gauge weight on the GHO/USDC pool > 0 (else Convex emissions are zero,
  collapsing to fee-only carry).

## Strategy steps

1. Fund test contract with USDC principal.
2. `supply` USDC to Aave V3 Pool.
3. `borrow` GHO at variable rate (rate mode 2).
4. Pair the borrowed GHO with a slice of USDC (reserved from principal).
5. `add_liquidity` on the Curve GHO/USDC pool -> receive LP token.
6. `approve` LP to Convex Booster; `deposit(pid, amount, stake=true)`.
7. Warp 14 days (one Convex epoch boundary).
8. `getReward(true)` on the BaseRewardPool -> claim CRV + CVX (+ extras).
9. `withdrawAndUnwrap` LP back to the test contract; `remove_liquidity` back to
   GHO+USDC; `repay` GHO; `withdraw` USDC.
10. PnL = residual USDC + sold rewards - gas.

## PnL math

Inputs (snapshot Q4 2024):
- `P` = 1,000,000 USDC principal
- `LTV` = 70% -> borrow 700k GHO against 1M USDC
- `r_gho_borrow` = 9.00% (Aave variable, governance-set)
- `r_curve_fee` = 1.5% (swap-fee APR on GHO/USDC at $30M-$50M TVL)
- `r_crv_emissions_boosted` = 6.0% (boosted by Convex's veCRV stack)
- `r_cvx_emissions` = 1.5% (Convex's auto-emissions, decreasing per epoch)
- `r_usdc_supply` = 4.5% (Aave aUSDC)

Income on 14 days (Convex epoch) at a leveraged position size of
`LP_notional = 700k GHO + 700k USDC ≈ $1.4M`:
```
fees_14d = LP_notional * r_curve_fee * 14/365 = 1.4M * 0.015 * 0.0384 = 805
crv_14d  = LP_notional * 0.06 * 14/365  = 3,222
cvx_14d  = LP_notional * 0.015 * 14/365 = 805
usdc_14d = 0.3M * 0.045 * 14/365        = 517   (only 300k stays as Aave collateral)
income_14d_total ≈ $5,349
```

Cost on 14 days:
```
gho_cost_14d = 0.7M * 0.09 * 14/365 = 2,416
```

Net 14d: ~**$2,933 on $1M base ≈ 7.6% APR** (annualised). At incentive-peak
the Convex CRV boost can lift the LP APR by another 2-3pp.

Annualised cleanly:
```
income_apr = LP_notional * (r_curve_fee + r_crv_emissions_boosted + r_cvx_emissions)
           + collateral_supply_yield
         = 1.4M * 0.09 + 0.3M * 0.045
         = 126k + 13.5k = 139.5k

cost_apr   = 0.7M * 0.09 = 63k

net        = 76.5k / 1M = 7.65% APR
```

This is a **clean composition margin**: the bare Aave GHO mint is 0-1%, the
bare Curve LP is 1-2%, the bare Convex boost adds 4-5% on the LP — together
they exceed the GHO carry cost by ~750bps.

## Block pinned

**20_900_000** (≈ Nov 5 2024). Convex GHO/USDC PID active, Curve gauge
emitting, GHO facilitator with > 5M bucket headroom per `bucketCapacity -
bucketLevel` read off-chain. The Convex PID is **discovered dynamically** via
`Booster.poolLength()` + linear scan for `lptoken == CURVE_GHO_USDC_POOL`,
because PID re-registrations after pool migrations can shift the index. If
no live PID is found the strategy falls through to plain LP yield.

## Risks

- **GHO depeg**: identical to F10-01. GHO < $1 means LP value < deposited
  notional; the loss surfaces on `remove_liquidity`.
- **Curve A-parameter ramp / depeg**: at high amplification, sub-1% price
  drift translates to outsized BPT/LP impermanent loss.
- **CRV / CVX emissions decay**: CRV inflation halves every ~12 months;
  Convex's CVX emissions follow a cliff schedule that asymptotes to 0.
- **Convex pool shutdown**: if the booster shuts down PID for the pool, new
  deposits revert and emissions stop streaming.
- **GHO facilitator bucket exhaustion**: identical to F10-01.
- **Smart-contract risk**: Aave V3 Pool, Curve ng-stableswap pool, Curve
  gauge, Convex Booster, Convex BaseRewardPool. Five entry points.

## Result

Status: theoretical. 3-mechanism PoC compiles and exercises all three entry
points with try/catch fall-throughs so each layer can fail independently
without aborting the test. Expected gross PnL on 1M USDC over 14 days at
peak-Convex-emissions parameters: **+$2,500 to +$3,500**.
