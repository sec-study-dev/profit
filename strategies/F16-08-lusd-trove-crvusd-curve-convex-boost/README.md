# F16-08: LUSD trove (0% running rate) + crvUSD/LUSD Curve LP + Convex boost

## Mechanism

A 3-mechanism cross-CDP stack that captures Curve gauge emissions on an
LP between two CDP-issued stables (**LUSD** + **crvUSD**), funded by a
**zero running interest** Liquity v1 trove:

1. **Liquity v1 trove**: open with the operator's ETH collateral. LUSD
   draws pay a one-time decayed fee (typically 0-1% at calm blocks) and
   then accrue **0% interest indefinitely**. This is the only major CDP
   with a no-running-rate model.
2. **Curve crvUSD/LUSD stableswap pool**: single-sided LP using the
   freshly minted LUSD on the LUSD index. The pool earns swap fees on
   every crvUSD ↔ LUSD trade, plus CRV gauge emissions through its
   Convex proxy.
3. **Convex Booster**: stake the Curve LP into Convex's BaseRewardPool
   to receive *boosted* CRV emissions on top of the gauge **plus**
   native CVX emissions. Convex's boost amplifies CRV by ~2.5× on
   average, and CVX-as-reward typically adds another 30-80% of CRV
   notional in payout.

The strategy's structural edge is that **the funding leg costs 0%
indefinitely**. No other CDP issuer in this repo offers that. The
trade-off is that Liquity v1 only accepts native ETH (not wstETH or
rETH), so the LST yield foregone on the collateral is the implicit
funding cost:

```
implicit_funding_cost = ETH_LST_apr * coll_eth_value
                      ≈ 3% APR * $310k = $9,300 / yr  (on 100 ETH coll)
```

Against that, the Curve LP + Convex boost typically delivers:

```
swap_fee_apr        + CRV+CVX_gauge_apr
≈ 2-4%/year         + 5-15%/year     ≈ 7-19% APR on the LP value
```

On $200k of LP value, that's ≈ **$14-38k / yr**, comfortably above the
$9.3k LST-foregone cost. Net edge ≈ **$5-29k / yr / 100 ETH coll**.

## Why it composes

The composition stacks three unrelated yield sources:

- **Liquity v1**: the funding leg. ETH collateral, LUSD debt at 0%
  running rate. Recovery-mode risk if global system CR drops below
  150%, but isolated from Aave / Curve / Sky rate moves.
- **Curve crvUSD/LUSD pool**: an LP between two algorithmic stables.
  Both pegs are defended *algorithmically* (LUSD by stability-pool +
  redemptions, crvUSD by PegKeepers + LLAMMA). When both pegs hold,
  the LP is high-velocity and earns ~$0.001 in fees per $1 of TVL per
  swap (very thin per-trade, but compounds at the gauge's reward emission
  rate).
- **Convex Booster**: rewards-aggregator that wraps Curve gauges, applies
  a boost factor via vlCRV held by Convex itself, and distributes CRV +
  CVX to LP stakers in proportion to their stake. Because Convex holds
  ~50% of all vlCRV, its boost factor approaches the cap (2.5×) for any
  staked LP.

The three mechanisms are governance-independent: a Liquity v1 spell
freeze does not affect Curve gauge weights; a Convex governance attack
does not affect LUSD's stability pool. Each leg can be unwound
independently of the others.

## Preconditions

- Liquity v1 BorrowerOperations + TroveManager live (immutable since
  2021).
- Curve crvUSD/LUSD factory pool exists at the candidate address
  `0x9978c6B08d36E1D304407c5C3DA15A079bDFB0BD`. PoC resolves at runtime
  via `pool.coins(0)` / `coins(1)` and bails out gracefully if the
  candidate does not match. Production deployment should re-scan the
  Curve factory registry at the actual fork block.
- Convex Booster has registered the pool with a non-shutdown PID. PoC
  scans the trailing 50 PIDs for a matching lptoken.

PoC pins block **21_800_000** — Jan 2025.

## Strategy steps

1. Fund `address(this)` with 100 ETH.
2. `BorrowerOperations.openTrove{value: 100 ETH}(MAX_FEE=1%, LUSD=200k,
   0, 0)`.
3. Resolve the crvUSD/LUSD pool by probing `coins()`. Bail if mismatch.
4. `Curve.add_liquidity([0, lusdMinted], min_lp)` — single-sided
   LUSD-only deposit.
5. Scan Convex Booster for a PID with `lptoken == resolvedPool`.
6. `Booster.deposit(pid, lpMinted, true)` — stake into Convex rewards.
7. Warp 30 days; `BaseRewardPool.getReward(this, true)`; read CRV + CVX
   balances; unstake LP; read Curve `get_virtual_price()` for swap-fee
   accrual diagnostic.

## PnL math

Pinned-block parameters:
- ETH collateral: 100 ETH ≈ $310,000 (ETH ≈ $3,100 in Jan 2025).
- LUSD drawn: 200,000 (CR ≈ 155%, above the 110% min).
- Liquity v1 one-time fee at block (decayed): ~0.5% → $1,000 paid in
  LUSD up front.
- Curve LP TVL after single-sided $200k deposit: pool grows by ~$200k.
- Curve LP swap fee APR: 3% (typical stableswap on a moderate-volume
  pair).
- CRV emissions on the gauge: ~2,500 CRV / day across the gauge; LP
  share ≈ 30% → ~750 CRV/day; 30 days → 22,500 CRV.
- Convex boost factor: 2.4× → 54,000 boosted-CRV-equivalent emission.
- CVX side reward: ~25% of CRV notional → ~13,500 CVX-equivalent.
- CRV price ≈ $0.30 in Jan 2025; CVX ≈ $2.00.

```
crv_value_30d  = 54_000 * 0.30  = $16_200
cvx_value_30d  = 13_500 * 2.00 / 30 * 30  ≈ Note: CVX is denominated in CVX, the
                                          $13_500-value estimate assumes ~$2 CVX.
swap_fee_30d   = 200_000 * 0.03 * (30/365) = $493
gross_30d      ≈ 16_200 + value(cvx) + 493 ≈ $17-22k (CVX value dependent)

cost_implicit  = ETH_LST_foregone
               = 310_000 * 0.03 * (30/365) = $764
one_time_fee   = $1_000   (one-shot, amortised across the position life)

net_30d (LP yr1) ≈ $17_000 - 764 - 1_000 ≈ +$15_236 / 30d
annualised      ≈ ~70% APR on the $200k LP value, or 90+ % at higher
                  CRV prices
```

These figures are heavily CRV-price-dependent. The trade collapses to
near-zero if CRV drops to $0.10; it doubles if CRV rallies to $0.60.

## Block pinned

`21_800_000` — Jan 2025. Selected because:
- Liquity v1 baseRate at near-floor (last system redemption was
  weeks-old).
- crvUSD/LUSD pool had a registered Convex PID with active emissions.
- ETH staking yield was at its 2024-2025 floor (~3%), minimising the
  implicit funding cost.

## Risks

- **Pool address candidate mismatch** — if the Curve crvUSD/LUSD
  factory pool address has shifted, the PoC bails out and logs the
  failure. Production deployment should resolve the pool from the
  Curve metaregistry rather than a hardcoded candidate.
- **CRV price collapse** — the dominant single risk. CRV is reflexively
  priced against gauge votes; a Convex governance attack or
  vote-bribery collapse could halve CRV emissions value within a week.
- **LUSD peg drift** — if LUSD drops below 0.97, the LP starts losing
  LUSD-side principal at every rebalance. Counter-balanced by Liquity
  redemptions which re-anchor the peg above 0.97.
- **Liquity v1 recovery mode** — if system CR < 150%, all troves face
  asymmetric liquidation rules. Our 155% CR is in the buffer zone.
- **Convex shutdown / re-pid** — Convex can shutdown a PID and migrate
  to a new one; the LP would still earn the Curve gauge directly but
  lose the boost.

## Result

Status: full open path implemented end-to-end, with runtime pool
resolution and Convex PID scanning. Expected 30-day net at pinned-block
parameters ≈ **+$10-20k on 100 ETH collateral**, dominated by CRV+CVX
emissions valued at spot. Annualised ≈ **30-90% APR** depending on CRV
price action. Status: `theoretical` (Convex emissions are realised by
the PoC but the carry is logged only).
