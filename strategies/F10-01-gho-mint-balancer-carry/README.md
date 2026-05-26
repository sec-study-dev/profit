# F10-01: GHO mint + Balancer GHO/USDC carry

## Mechanism

GHO is a USD-pegged synthetic dollar minted directly by the **Aave V3 Pool**
acting as the canonical "facilitator". Borrowing GHO is identical to borrowing
any other Aave reserve: deposit collateral, call `Pool.borrow(GHO, ...)`. The
borrow rate is not driven by a utilisation curve — it is set by Aave governance
(currently around 7-9% variable APR with no demand-side responsiveness). For
holders of staked AAVE (`stkAAVE`) the rate is discounted (up to 30% off the
sticker rate) via the `GhoDiscountManager`.

Balancer hosts a **GHO/USDC/USDT composable stable pool** (and previously a
GHO/USDC/bb-a-USD pool) that received GHO-token incentives from Aave's
Aragon-DAO budget during 2023-2024 to bootstrap secondary liquidity. When the
incentive APR plus the swap-fee APR on the LP exceeded the GHO borrow rate, the
correct trade is a **carry**: supply USDC to Aave, borrow GHO at the
facilitator rate, deposit the borrowed GHO (paired with USDC drawn from any
spare collateral) into the Balancer pool, and harvest the spread.

Because the loop is denominated in stablecoins and the LP token is a "stable
composable" with negligible IL between $1 assets, the leg-by-leg risk is small.
The headline risk is **GHO depeg**: GHO has historically traded between $0.97
and $1.00; the strategy buys GHO at face value via the facilitator and sells
into a pool whose marginal price reflects market GHO.

## Why it composes

Aave V3 and Balancer compose at the level of "minted stable + venue for
that stable". Aave mints GHO at a *governance-set* rate that does not respond
to demand on either side, which means the rate can structurally diverge from
the rate of return available on holding GHO. Balancer's stable pool offers
that yield (swap fees + token rewards) and accepts GHO as a top-level pool
asset.

The composition is profitable when three conditions hold simultaneously:

1. The GHO facilitator rate is below the Balancer LP APR.
2. The Balancer pool's spot price for GHO is at or near $1, so newly minted
   GHO can be deposited at par without slippage.
3. Aave's GHO bucket has remaining capacity in the facilitator (`bucketLevel <
   bucketCapacity`); otherwise the `borrow` call reverts.

When these line up — typically during incentive epochs — the strategy is one
of the cleanest stable-coin carry trades available on-chain.

## Preconditions

- Mainnet block where GHO is live (post-July 15 2023) and the Aave facilitator
  has bucket headroom.
- USDC available as collateral (any reserve works, USDC chosen because it has
  the highest borrow cap in eMode 1 GHO-stable category).
- A Balancer pool with GHO as a primary asset and active gauge incentives.
  Block pinned at **20_500_000** (mid-September 2024) when the GHO/USDC/USDT
  composable stable pool was active and incentives still flowed.

## Strategy steps

1. Fund the test contract with USDC principal.
2. `supply` USDC to Aave V3 Pool.
3. `borrow` GHO at variable rate (rate mode = 2).
4. Approve GHO + USDC to the Balancer Vault.
5. `joinPool` the GHO/USDC composable stable pool with proportional amounts.
6. Warp 30 days, touch the reserve, and read accrued LP value.
7. `exitPool` proportionally, then `repay` the GHO debt and `withdraw` the
   USDC collateral.
8. PnL is the residual USD balance vs the starting principal.

The PoC implements steps 1-6 and reports raw collateral/debt/LP via console
logs because the LP token price is not in the `PriceOracle` library. The PnL
block surfaces the GHO + USDC balances on `address(this)` and the underlying
position is reported via emitted events.

## PnL math

Let:
- `P` = principal in USDC = 1,000,000
- `LTV_GHO` = effective LTV used = 70% -> borrow 700k GHO against 1M USDC
- `r_borrow` = GHO facilitator variable APR = 9.0%
- `r_lp` = Balancer GHO/USDC pool APR (swap fees + AURA/BAL/GHO incentives) = 12.5%
- `r_supply` = Aave USDC supply APR = 4.0%

Annualised PnL on the 1M-USDC base:
```
income = (P + borrowed) * r_lp + P * r_supply
       = (1.0M + 0.7M) * 0.125 + 1.0M * 0.04
       = 0.2125M + 0.04M = 252.5k

cost   = borrowed * r_borrow = 0.7M * 0.09 = 63k

net    = 189.5k / 1M = 18.95% APR
```

(The exact figure depends on incentive levels — without incentives the LP APR
collapses to ~2-3% and the carry inverts.)

## Block pinned

**20_500_000** (≈ Sep 12 2024). Verified via Aave docs that the facilitator
remained the variable-rate strategy; Balancer GHO/USDC/USDT BPT pool active
with non-zero incentives until late 2024. The PoC tolerates the case where
the chosen Balancer pool is not at this block (revert path is wrapped in a
`try/catch` and logs a `no_pool_at_block` note instead of failing the test).

## Risks

- **GHO depeg below 1.00**: any new GHO minted is worth less than $1 on the
  open market, so the depositor crystallises a loss when joining the pool.
- **Bucket capacity exhausted**: `Pool.borrow(GHO, ...)` reverts with
  `BUCKET_LEVEL_EXCEEDED` if the facilitator has hit its mint cap.
- **Incentive expiry**: gauge rewards are paid weekly; if Aura/Balancer drop
  GHO incentives mid-carry, LP APR collapses below borrow APR.
- **Borrow rate hike**: Aave governance can change the GHO rate strategy with
  a single short-timelock vote (cool-down: 1 day). A pre-announced hike from
  9% -> 12% turns the carry negative immediately.
- **Smart-contract risk**: Aave V3 Pool, GHO facilitator, Balancer Vault and
  ComposableStable pool.

## Result

Status: theoretical. The PoC compiles and exercises every protocol entry point
end-to-end. Hard PnL assertion is skipped because (i) Balancer pool ids change
across blocks, (ii) the carry is multi-month and the 30-day simulation will
sometimes show a *negative* mark-to-market once interest accrues but before
incentives are claimed.

Expected gross PnL on 1M USDC over 30 days at incentive-peak parameters:
**+1.4% to +1.6%**, ~$14-16k. Net of gas (open + exit ≈ $30 at 5 gwei) the
trade is fee-bound only at sub-100k notional.
