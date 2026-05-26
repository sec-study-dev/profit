# F16-07: Five-stable cross-CDP basis surface scan

## Mechanism

A non-trading **observation strategy** that surfaces the live cross-CDP
basis matrix between every pair of CDP-issued stables on mainnet. It is
the upstream "router" that drives strategy selection for the rest of the
F16 family (and downstream families F04, F05, F06, F10).

The five stables surveyed:

| # | Stable  | Issuer       | Rate model                                      |
|---|---------|--------------|-------------------------------------------------|
| 1 | DAI/USDS| Maker/Sky    | DSR (USDS-side) + Spark borrow rate (DAI-side) |
| 2 | GHO     | Aave V3      | Governance-set fixed APR with bucket cap        |
| 3 | crvUSD  | Curve LLAMMA | Per-second algorithmic rate (PegKeeper feedback)|
| 4 | LUSD    | Liquity v1   | One-time borrow fee + 0% running rate           |
| 5 | BOLD    | Liquity v2   | User-chosen annual interest rate (paid on debt) |

3-mechanism stack inside the scan body:

1. **Aave V3 IRM reads** — DAI, GHO, USDC variable borrow rate + supply
   rate (in RAY per-second).
2. **Curve LLAMMA per-second rate read** — `rate()` on the wstETH-market
   AMM contract; converted to APR via `r * 365 * 86400`.
3. **Sky SSR + Liquity v1 baseRate reads** — `sUSDS.ssr()` and
   `TroveManager.getBorrowingRateWithDecay()` for the issuer-specific
   stable yield/cost.

For each issuer the scan reports:
- **Borrow APR** in bps
- **Supply APR** (if applicable) in bps
- **Curve mid-quote** to USDC for a 100k-unit probe (slippage proxy)

The matrix is then synthesised into **refi opportunity flags**: pairs
where `(borrow_i - borrow_j) > swap_round_trip_fee + risk_premium`,
i.e. the trader should *close their debt in stable i and re-mint as
stable j*.

## Why it composes

Every CDP issuer has its **own** rate-setting mechanism, and the
mechanisms are *uncorrelated* on short horizons:

- Aave GHO rate is set by 6/14 governance approvals; updates take days.
- Curve crvUSD rate is algorithmic and updates *every block* as crvUSD
  market price drifts.
- Sky SSR is set by Sky Governance; updates are infrequent (~once per
  quarter).
- Liquity v1 baseRate decays exponentially after every redemption / loan
  open; updates continuously.
- Liquity v2 BOLD has a *user-chosen* rate, but the **system-redemption
  threshold** is the median rate across all troves.

Because the rate setters are independent, the pairwise basis can be
wide (50-200 bps is typical) and stays wide for days at a time. A
scanning strategy that runs daily and re-routes large stable-debt
positions captures the **basis convergence** without taking
directional risk.

## Preconditions

- All five issuer contracts must be live at the pinned block:
  - Aave V3 Pool with GHO, DAI, USDC reserves enabled.
  - Curve crvUSD wstETH-market `0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE`.
  - Sky sUSDS deployed (post Sep 2024).
  - Liquity v1 TroveManager `0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2`.
  - Liquity v2 BOLD `0x6440f144b7e50D6a8439336510312d2F54beB01D`
    (post May 2025 v2 redeployment).
- Curve pool venues live: 3pool, crvUSD/USDC NG, GHO/crvUSD,
  LUSD/3pool meta.

PoC pins block **23_000_000** — Aug 2025. Selected because BOLD's v2
redeployment in May 2025 must be settled with several months of trove
activity before the rate is informative.

## Strategy steps

The PoC is a **read-only scan**. It performs:

1. Read Aave V3 `ReserveDataLegacy` for DAI, GHO, USDC. Extract
   `currentVariableBorrowRate` and `currentLiquidityRate`. Convert RAY
   to bps.
2. Read Curve crvUSD wstETH-market `LLAMMA.rate()` (per-second e18).
   Convert to APR bps.
3. Read `sUSDS.ssr()` (RAY per-second). Convert to APR bps.
4. Read Liquity v1 `TroveManager.getBorrowingRateWithDecay()` (1e18 =
   100%). Convert to one-time fee bps.
5. Probe Curve mid-quotes:
   - `3pool.get_dy(DAI, USDC, 100k)` → slippage on Maker-side.
   - `crvUSD/USDC.get_dy(crvUSD, USDC, 100k)` → slippage on Curve-side.
   - `GHO/crvUSD.get_dy(GHO, crvUSD, 100k)` and reverse → GHO/crvUSD
     two-sided depth.
   - `LUSD/3pool.get_dy(LUSD, USDC, 100k)` → LUSD venue slippage.
6. Synthesise refi flags:
   - `refi_GHO_to_crvUSD_edge_bps = ghoBorrow - crvUsdBorrow` if > 100.
   - `refi_DAI_to_crvUSD_edge_bps = daiBorrow - crvUsdBorrow` if > 100.
   - `refi_GHO_to_DAI_edge_bps = ghoBorrow - daiBorrow` if > 100.
   - `refi_GHO_to_LUSD_1yr_edge_bps = ghoBorrow - lusdBorrowFee` if
     LUSD is cheaper over 1-year horizon (since LUSD running rate = 0).
   - `refi_DAI_to_LUSD_1yr_edge_bps = daiBorrow - lusdBorrowFee` if
     applicable.

All values are logged via `emit log_named_uint`/`emit log_named_int`.
No state-mutating calls.

## PnL math

The scan itself produces no PnL. The downstream impact is the **refi
savings** captured by F16-02 / F16-06 / F16-08 (and F04-02 / F05-03 /
F10-04 in other families) when the matrix surfaces an edge. Expected
quarterly value of acting on a single 100-bps refi opportunity, sized
at 1M of the cheap-side stable:

```
quarterly_refi_value = notional * spread_bps * (90 / 365)
                     = 1_000_000 * 0.0100 * 0.247
                     ≈ $2_470 / quarter / opportunity
```

A typical scan surfaces 2-4 refi flags per scan window, so the **scan
contributes ~$8-12k of annualised value per 1M of basis-trading capital
that uses it**.

## Block pinned

`23_000_000` — Aug 2025. All five issuers active, Liquity v2 trove
population has settled into a stable rate distribution (median ~5%
annual), and Sky's SSR has been at 6-7% for two consecutive quarters
(enough to be considered a stable signal).

## Risks

- **Read drift**: the matrix is a *snapshot*. The crvUSD per-second rate
  can move 50 bps in a single block during a peg attack. A consumer of
  the scan should re-read just-in-time, not rely on a stored matrix.
- **Curve pool depth**: low-depth pools give misleading mid-quotes. The
  scan logs the 100k probe explicitly so the consumer can apply a
  size-adjusted slippage model.
- **Liquity v1 baseRate decay**: `getBorrowingRateWithDecay()` is
  decaying exponentially since the last open or redemption. The reported
  fee is a *moving* number; a strategy that uses this should re-read
  immediately before opening a trove.
- **BOLD median rate** is not directly exposed; the user must derive it
  from the system redemption queue. The PoC notes this rather than
  attempting an aggregation.

## Result

Status: pure read-only scan. Logs all five issuers' rates + four
pairwise Curve quotes + 5 cross-CDP refi flags. No PnL is realised in
the test body; the scan is the **input** that downstream strategies
(F16-02, F16-06, F16-08, F04-02, F10-04) consume. Expected value of the
scan, amortised over the strategies that depend on it, is **~$10k/yr
per 1M of basis-trading book**. Status: `theoretical`
(read-only/diagnostic).
