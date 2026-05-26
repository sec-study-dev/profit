# F10-08: Aave V3 isolation-mode early-incentive farming

## Mechanism

Aave V3 introduced **isolation mode** in 2022 as a risk-isolated listing path
for new collateral assets. When an asset is listed in isolation mode:

- It can be supplied as collateral, but the user can only borrow **specific
  isolation-mode-allowed reserves** (typically the stablecoin set: USDC,
  USDT, DAI, GHO).
- A **debt ceiling** is applied per-asset (denominated in 1e2 USD); once the
  protocol-wide isolation debt against the asset is reached, new borrows
  revert. The ceiling is typically set 5-20M USD on first listing and is
  raised by governance over several weeks.
- The asset's deposit cap is also set conservatively (the listed cap is a
  hard ERC20 supply ceiling).

When governance lists a new asset with **deposit incentives** (typically
denominated in AAVE or in the asset itself), the early depositor capture is
disproportionate because (i) the deposit cap is small, (ii) total supply is
low so the per-supplier APR is high, and (iii) the incentive program runs
for a fixed window irrespective of how the cap fills.

This strategy is a **probe-and-deposit** PoC: it scans on-chain for the
current isolation-mode reserves on Aave V3, reads their `debtCeiling`,
`supplyCap`, `currentLiquidityRate` and `isolationModeTotalDebt`, and
attempts to deposit a small notional into the highest-incentive reserve
that has remaining headroom. The position is closed after a 30-day warp.

The PoC focuses on **observability** rather than asserting a profitable
outcome: incentive APRs change weekly, and the value of an isolation
deposit depends on the asset's price-volatility track record (a new LSD
listed in isolation mode is often the highest-incentive but
highest-vol slot).

## Why it composes

This is a **2-mechanism** strategy: Aave V3 + the isolated asset's native
yield (in cases where the isolated asset itself accrues yield, e.g. an LST).
The composition is Aave's risk-isolation mechanism *plus* the AAVE rewards
emissions paid by the Aave Safety Module budget on isolation-mode supplies.

The opportunity exists because new listings receive a **fixed-budget reward
stream** divided by total supply — the first 10M of supply earns much higher
per-unit yield than the next 10M. Isolation mode caps the supply that any
single position can capture, but the cap also caps the *total* supply that
competing depositors can stack against your slot, so the cap *helps* an
early entrant rather than hurts them.

## Preconditions

- Mainnet block where a new isolation-mode asset is freshly listed with
  active incentive emissions. Pinned at **20_600_000** (≈ Sep 26 2024) when
  the Aave V3 protocol listed two assets in isolation mode (notably
  **rsETH** and **USDe** at various points; pinned-block reads what is
  active and selects).
- Aave V3 incentives controller is funded with AAVE for the active reserves.

## Strategy steps

1. Iterate the Aave V3 reserve list and read each reserve's configuration.
2. Identify reserves where the **isolation-mode bit** is set in the
   `configuration` bitmap (bit 64) AND `debtCeiling > 0` (debt ceiling > 0
   confirms active isolation listing).
3. For each candidate, read `isolationModeTotalDebt` vs `debtCeiling` to
   confirm headroom; read `currentLiquidityRate` to estimate baseline APR.
4. Pick the highest-yield candidate with > 50% headroom. Deposit a small
   notional (cap: 50k of the asset, or 1% of supplyCap, whichever is smaller).
5. Borrow ~30% of available against the deposit in USDC (allowed because
   USDC is an isolation-mode-borrowable reserve).
6. Warp 30 days; touch the reserve.
7. Read accrued aToken balance; surface the implied APR via `(aTokenBalEnd -
   aTokenBalStart) / aTokenBalStart * 365/30`.

The PoC is **purely observational**: no hard PnL assertion, because the
chosen asset and yield are block-dependent. It surfaces the candidate list
and the open-position metrics as console logs that Wave 3 sweeps can analyse
across blocks.

## PnL math

Inputs (worked example using rsETH isolation slot at FORK_BLOCK):
- `P_rseth` = 20 rsETH (~$60k @ $3000 ETH)
- `r_supply_apr_rseth` = 0.20% (low because the gauge captures most yield)
- `r_incentive_apr` (AAVE emissions on rsETH supply) = 4.50%
- `borrow_usdc` = 30k USDC (50% LTV)
- `r_borrow_usdc` = 6.50%

Annualised on the 60k notional:
```
income = P * (r_supply_apr + r_incentive_apr) + idle_usdc_yield(*)
       = 60k * 0.047 = 2.82k
cost   = borrow * r_borrow = 30k * 0.065 = 1.95k

net    = 0.87k / 60k = 1.45% APR
```

(*) The borrowed USDC can be redeployed into Aave aUSDC or sUSDS for ~5%
APR, lifting the net to ~3.5% APR. The PoC skips this redeployment to keep
the isolation-mode mechanism the **single observable variable**.

## Block pinned

**20_600_000** (≈ Sep 26 2024). At this block at least one Aave V3 isolation-
mode reserve has fresh AAVE incentives (read via the on-chain incentives
controller). The PoC enumerates the reserve list dynamically; the picked
asset is identified at runtime via a `log_named_address("isolation_pick", ...)`.

## Risks

- **Isolation-asset depeg / vol**: the assets listed in isolation mode are
  by definition the highest-risk additions. Liquidation thresholds are tight
  (5-10% buffer above LTV).
- **Debt ceiling raise**: governance can raise the ceiling, which dilutes
  per-supplier incentive APR.
- **Incentive program expiry**: the AAVE emissions stream is fixed-duration;
  when the budget runs out the APR collapses to the bare lending rate.
- **Smart-contract risk**: Aave V3 Pool, Aave V3 IncentivesController.

## Result

Status: theoretical / observational. The PoC compiles and runs the
isolation-mode candidate enumeration even when no candidate has incentive
emissions at the pinned block; in that case it emits a
`no_isolation_candidate` log and exits gracefully without asserting a
PnL number. The strategy's value is as a **scanner** that Wave 3 sweeps can
run at multiple block heights to detect the windows where a fresh listing
prints a high per-supplier incentive APR.

Mechanism count: **2** (Aave V3 isolation-mode + native asset yield). Does
not count toward the ≥2 three-mechanism requirement; F10-05, F10-06, F10-07
satisfy that constraint.
