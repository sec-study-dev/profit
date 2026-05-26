# F10-04: GHO mint with stkAAVE discount + sDAI/USDS carry

## Mechanism

GHO's borrow rate on Aave V3 is governance-set (currently ~9% variable). To
incentivise long-term AAVE staking, the GHO facilitator implements a **discount
strategy**: holders of staked AAVE (`stkAAVE`, the Aave Safety Module token)
receive a per-token discount on their GHO borrow rate. The published schedule
on launch was:

- 100 stkAAVE -> discount on up to ~10,000 GHO of debt
- Discount factor: 20-30% off the sticker rate

So with 100 stkAAVE and 10k GHO debt, an 9% borrow APY becomes effectively
~6.3% APY. Adjustments to the discount parameters require a 1-2 week Aave
governance cycle, so on any given block the discount-rate setting is
deterministic and can be read on-chain from `GhoDiscountRateStrategy`.

This strategy captures the discount by **borrowing right at the discount cap**
(no more, no less, since beyond-cap debt pays the full rate), then deploying
the borrowed GHO into a **stable-coin carry**: convert GHO -> USDC (via
Curve or PSM-equivalent), USDC -> USDS (via Sky upgrade), USDS -> sUSDS
(Sky's DSR-equivalent ERC-4626). With sUSDS yielding ~6-7% during 2024-2025
and the discounted GHO borrow rate at ~6.3%, the carry is positive 0-1%
per unit of debt, plus the AAVE-Safety-Module yield on the stkAAVE itself
(historically 4-7% APR in AAVE+GHO emissions).

Total expected return:
```
return on stkAAVE deposit  : 5% AAVE/GHO emissions
+ carry on GHO debt -> sUSDS: (6.5% - 6.3%) = 0.2%
- gas / claim friction
≈ 5.0-5.5% APR on the stkAAVE notional, with ~0% net carry on the GHO debt.
```

When the GHO borrow rate is *raised* by governance (e.g. 9% -> 12%) without a
matched lift in sUSDS / DSR, the carry inverts. Conversely when DSR or sUSDS
spikes above the discounted GHO rate, the trade is unambiguously positive.

## Why it composes

The composition stacks three Aave-anchored mechanisms with a Maker-anchored
deposit leg:

1. **stkAAVE Safety Module** — Aave's first-loss capital pool, earning safety
   rewards.
2. **GhoDiscountRateStrategy** — couples stkAAVE balance to GHO borrow rate.
   Aave engineered this specifically so the SM has *two* yields (safety
   rewards + borrow-rate subsidy), increasing AAVE token utility.
3. **GHO facilitator** — mints GHO at the discounted rate when a user holds
   sufficient stkAAVE.
4. **sUSDS / Sky Savings Rate** — independent yield surface on Sky-anchored
   stables.

The trade is profitable only when the discount-adjusted GHO rate is below the
sUSDS rate. Because the GHO sticker rate and the SSR are set by different
governance bodies (Aave vs Sky) on different cadences, this happens
non-trivially often.

## Preconditions

- Mainnet block where:
  - GHO is live with stkAAVE discount active (post-July 2023).
  - Sky USDS / sUSDS are deployed (post-Sept 5 2024).
  - Aave V3 GHO facilitator has bucket headroom.
- The agent holds (or can be funded with) stkAAVE for the discount.
- `address(this)` must satisfy the discount-rate strategy's eligibility
  (no special checks beyond `stkAAVE.balanceOf > 0`).

## Strategy steps

1. Fund `address(this)` with USDC principal and with stkAAVE (via `_fund` —
   note stkAAVE may have transfer restrictions; if so, fall through to a
   non-discounted variant and emit a log).
2. Supply USDC to Aave; borrow GHO at variable rate. Because address(this)
   holds stkAAVE, the discount applies *automatically* via the
   `userDiscountToken` callback on every borrow / repay.
3. Snapshot GHO debt + emit the discount-applied per-second rate from the
   variable debt token.
4. Convert borrowed GHO -> USDC via the Curve GHO/USDC/USDT/DAI pool (if
   available at block) or via a direct Balancer swap.
5. USDC -> USDS via Sky's `DaiUsds` converter at parity. (Skipped if pre-Sky
   block.)
6. USDS -> sUSDS via `SUSDS.deposit`.
7. Warp 30 days; touch the reserves; redeem.

## PnL math

Inputs:
- `P_usdc` = 100,000 USDC supplied
- `stkAAVE_held` = 1,000 stkAAVE (sufficient discount for ~100k GHO debt)
- `GHO_borrowed` = 70,000 GHO
- `r_GHO_sticker` = 9.00%
- `r_discount` = 30% off  -> effective rate = 6.30%
- `r_sUSDS` = 6.50%
- `r_USDC_supply` (Aave) = 4.50%
- `r_stkAAVE` (Safety Module) = 5.50%

Annualised PnL on the *combined* 100k USDC + 1k stkAAVE (~$80k @ $80/AAVE):
```
income = P_usdc * r_USDC_supply           # 4.5k
       + GHO_borrowed * r_sUSDS           # 4.55k
       + stkAAVE_notional * r_stkAAVE     # 4.4k
       = 13.45k

cost   = GHO_borrowed * r_discount        # 4.41k

net    = 9.04k / 180k = 5.02% APR
```

The leveraged-style component is small (~14bp on the carry); the dominant
return is the SM yield (`r_stkAAVE`) plus the USDC supply yield. The
GHO-leg is "free" in the sense that it pays for itself via sUSDS.

## Block pinned

**21_500_000** (≈ Dec 18 2024). Post-Sky launch (sUSDS live), Aave V3 stable
operations, GHO discount strategy in canonical form. The pinned block
verifies that the discount strategy contract address is reachable and that
the variable-debt token reflects the discount.

**Note:** `stkAAVE` minting via `deal()` may fail because the Safety Module
contract uses a non-standard `balanceOf` (cooldown + voting weight). If the
fund step reverts, the PoC falls through to a non-discounted comparison run
and logs `stkaave_unfundable`.

## Risks

- **stkAAVE cooldown / unstake delay**: closing the position requires 10
  days of cooldown + a 2-day window to unstake. The PoC assumes hold; an
  actual deployment must factor in the exit cost.
- **Discount-strategy renumbering**: Aave can redeploy the discount strategy
  contract; existing positions migrate automatically but the per-token
  discount can be reduced by governance.
- **GHO depeg**: any pre-existing GHO depeg below $0.97 makes the borrowed
  GHO worth less than the sUSDS notional acquired at $1.
- **sUSDS rate cut**: Sky can cut SSR; carry inverts.
- **Aave safety-module slashing event**: stkAAVE can be slashed up to 30%
  to cover protocol shortfalls.
- **Sky DaiUsds converter availability**: routing GHO -> USDS depends on
  Sky's converter being live; pre-Sept-2024 blocks force a USDC->DAI->sDAI
  path instead.

## Result

Status: theoretical (forge build not run; stkAAVE balance write is
best-effort via `deal()`). Expected gross PnL over 30 days on the combined
100k USDC + 1k stkAAVE position: **+$750 to +$900 USD**, or ~5% APR on the
total notional. Most of that return is *not* from the GHO carry — it is
from the safety-module yield. The strategy's value is in stacking that
yield with a near-cost-free GHO borrow.
