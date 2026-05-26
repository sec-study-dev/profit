# F16-02: GHO mint vs crvUSD borrow — cross-CDP rate basis

## Mechanism

GHO and crvUSD are both newer-generation CDP stablecoins minted against
collateral, but they price the cost of debt very differently:

- **GHO (Aave)** — minted via the Aave V3 Pool when a user deposits collateral
  and calls `Pool.borrow(GHO, ...)`. The borrow APR is **governance-set**,
  decoupled from utilisation. Holders of `stkAAVE` receive a discount of up
  to 30%. In 2024 the variable rate hovered ~9-9.5%.
- **crvUSD (Curve)** — minted via per-collateral `Controller.create_loan`,
  with the borrow rate driven by a **pegkeeper-based** algorithmic feedback
  loop. The rate auto-adjusts each block to push crvUSD's spot back to $1: if
  crvUSD trades < $1 the rate rises; if > $1 the rate falls. In benign
  conditions the wstETH market borrow rate hovers ~6-12% but periodically
  dips to ~2-3% when crvUSD trades over peg.

The **cross-CDP basis** here is the difference between the two borrow rates:
`r_GHO - r_crvUSD`. When this number is positive (GHO is more expensive),
the trade is **short GHO, long crvUSD**: borrow crvUSD cheaply against wstETH
collateral, swap crvUSD -> USDC -> GHO, use the GHO to repay any outstanding
GHO position (refi). When negative (crvUSD is more expensive), the reverse:
borrow GHO cheaply, repay crvUSD.

This PoC focuses on the **opportunistic refinancing** angle: a user holding
GHO debt should move it to crvUSD when `r_crvUSD < r_GHO - swap_cost`, and
vice versa. The swap cost is ~10-30 bps round-trip on Curve crvUSD/USDC plus
Balancer GHO/USDC, so the *trigger threshold* is approximately a 100-200 bp
rate gap before the refinance is worth the gas + slippage.

A more aggressive use of the basis is **carry**: when the gap is wide and
persistent (say 400+ bps), an operator can:

1. Deposit collateral on the cheap side (e.g. crvUSD wstETH market @ 4%).
2. Borrow the cheap stablecoin.
3. Swap to the expensive stablecoin.
4. Deposit on the expensive side's lending market (Aave V3 GHO supply pool
   currently does not exist — GHO is supply-disabled — so the carry must use
   the Aave V3 *USDC* supply side after swapping GHO -> USDC, or hold the GHO
   as collateral itself if a venue accepts it).

The PoC implements the **rate-read + refinance-mock** path: it reads the
current GHO variable rate and crvUSD wstETH-market borrow rate, computes the
basis, and *if* the basis exceeds a configurable threshold, simulates the
crvUSD borrow leg + Curve swap leg and emits a refinance-feasibility log.
A full closed-loop refinance is not executed because (a) we don't have an
open GHO position to migrate, and (b) the strategy is dominated by the
rate-edge, not the swap mechanics.

## Why it composes

GHO and crvUSD live in two genuinely different rate regimes:

- GHO's rate is **off-chain governance** — slow to change, possibly weeks of
  inertia after a rate proposal.
- crvUSD's rate is **on-chain algorithmic** — adjusts every block based on the
  pegkeeper imbalance.

The two rate engines do not coordinate. So whenever the algorithmic engine
pushes crvUSD borrow well below the static GHO rate (or vice versa), the basis
opens. Historically the basis has been **structurally positive** in favour of
GHO being expensive: AAVE governance keeps GHO rates high to discourage GHO
debt-financed selling that would depress the peg; crvUSD's algorithm is happy
to let the borrow rate fall when crvUSD is over $1.

## Preconditions

- Mainnet block where:
  - Aave V3 GHO is live with a non-zero variable borrow rate.
  - The Curve wstETH crvUSD market (`Controller @ 0x100dAa...4C6CE`) has
    bucket headroom.
  - Curve crvUSD/USDC NG pool is operational.
- Available wstETH collateral.

PoC pins block **20_500_000** (mid-September 2024) when:
- GHO variable rate ~9.0%.
- crvUSD wstETH market borrow rate ~6.5%.
- Basis ≈ **+250 bps** in favour of refinancing GHO → crvUSD.

## Strategy steps

1. Fund test contract with wstETH (collateral).
2. Read `Pool.getReserveData(GHO)` to extract variable borrow rate in ray.
3. Read crvUSD `wstETH Controller.amm()`, then `LLAMMA.rate()` (or via the
   monetary policy contract) to extract the per-second rate.
4. Compute basis in bps.
5. If `basis > THRESHOLD_BPS`, execute the cheap side: open crvUSD loan
   against wstETH, draw crvUSD, swap crvUSD -> USDC on the NG pool.
6. The resulting USDC is the "synthetic GHO" that would have been used to
   close an outstanding GHO debt at the start of the trade. Log it for
   downstream PnL accounting.

The PoC implements steps 1-6 and explicitly does *not* close a GHO
position — there isn't one to close in the PoC's stateless world. Instead
it logs the realised synthetic-GHO amount and the implied annualised
savings.

## PnL math

Let:
- `D` = GHO debt being refinanced = 200_000 GHO
- `r_GHO` = 9.0% APR
- `r_crvUSD` = 6.5% APR
- `swap_cost_bps` = 20 bps (Curve NG pool + GHO/USDC return swap)
- horizon T = 1 year (assume the refinanced position is held to maturity)

Annual cost savings:
```
savings_per_year = D * (r_GHO - r_crvUSD)
                 = 200_000 * (0.09 - 0.065)
                 = $5_000
```

One-shot setup cost:
```
setup = D * swap_cost_bps / 10_000
      = 200_000 * 0.002 = $400
```

Net PV at 1y horizon (zero discount):
```
PV_net = savings_per_year - setup
       = 5_000 - 400 = $4_600
```

Equivalently, the breakeven horizon is `setup / savings_per_year ≈ 29 days`.
Beyond ~one month the refinance is in the money.

## Block pinned

`20_500_000` — Sep 12 2024. Cross-checked Aave docs (GHO rate ≈ 9%) and Curve
wstETH market (≈ 6.5%). Real basis on the day was ~250 bps in favour of
crvUSD.

## Risks

- **Rate engine reversal**: crvUSD's algorithmic engine can crank its rate
  above GHO's within a single block if crvUSD depegs below $1. The strategy
  must monitor the basis continuously and unwind if it inverts.
- **Liquidation curve mismatch**: GHO uses Aave's "health factor" model with
  discrete liquidation thresholds; crvUSD uses LLAMMA bands that
  soft-liquidate over a price range. Migrating debt between them changes the
  risk profile of the collateral.
- **Swap depth**: crvUSD/USDC and GHO/USDC pools are smaller than the
  3pool/DAI legs; sizes above ~$5 M see meaningful slippage.
- **AAVE governance**: rate change with a 1-day cool-down. A pending rate cut
  on GHO can compress the basis before the position is fully unwound.

## Result

Status: rate-monitor + cheap-side execution implemented in PoC. Expected
annualised savings on a $200k debt position at the pinned block: ~$4.6k net,
i.e. a **2.3% APR rebate** versus holding the GHO debt unchanged.
