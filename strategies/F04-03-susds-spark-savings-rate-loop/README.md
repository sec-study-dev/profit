# F04-03: sUSDS leveraged via DAI borrow on Spark (Sky Savings Rate spread)

## Mechanism

Sky (Endgame-rebranded MakerDAO) introduced **USDS** and **sUSDS** in 2024 as
parallel rails to DAI/sDAI. The crucial difference: sUSDS accrues at the
**Sky Savings Rate (SSR)**, which Sky governance has consistently set
*higher* than the DSR (the SSR is essentially a USDS-only incentive for
people who move from DAI to USDS).

The Maker/Sky primitives we stack:

1. **sUSDS (`0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`)** — ERC-4626 over
   USDS. `chi()` accrues at `ssr()` (RAY/sec). Through most of 2024-2025 the
   SSR has been 50-300 bps *above* the DSR.
2. **USDS (`0xdC035D45d973E3EC169d2276DDab16f1e407384F`)** — Sky's
   stablecoin, convertible 1:1 with DAI via the **DaiUsds wrapper**
   (`0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A`, the SKY `MCD_LITE_PSM`-paired
   DAI/USDS converter). The wrapper exposes `daiToUsds(address usr, uint256 wad)`
   and `usdsToDai(address usr, uint256 wad)` — zero-fee, atomic.
3. **Spark Pool** lists `sUSDS` as collateral (Spark added sUSDS at LTV 75% in
   the Phoenix Labs spell of late 2024). The borrow asset is **DAI** — Spark
   does not yet have a USDS reserve, so the canonical loop is:
   `USDS -> sUSDS -> Spark collateral -> borrow DAI -> DaiUsds wrap to USDS ->
   sUSDS -> ...`

## Why it composes

This loop is *unique to the Sky stack*. It needs:

- A higher-rate ERC-4626 (sUSDS, SSR > DSR by governance design).
- A zero-fee USDS<->DAI wrapper (DaiUsds), so the borrowed DAI can be cycled
  back into USDS without a stableswap slip.
- A money market (Spark) where the collateral asset (sUSDS) and borrow asset
  (DAI) are both Maker-blessed.

No other ecosystem offers a leveraged loop where one rate is set ~150 bps above
the other by the *same* governance entity that controls both legs, with a
free 1:1 conversion between them. The structural spread is intentional — Sky
incentivizes USDS adoption.

The arithmetic:
```
APY_net = L * SSR - (L - 1) * Spark_DAI_borrow_APY
```
At `L = 2.5x`, `SSR = 6%`, `Spark borrow = 5.5%`:
`APY_net = 0.06 + 1.5 * 0.005 = 0.0675 = 6.75%` on equity (vs 6% naked
sUSDS). When SSR is materially above DSR (e.g. the 12.5% SSR / 8.75% DSR
period in mid-2024), the loop yields >15% on equity.

## Preconditions

- Block after sUSDS was listed on Spark with positive supply cap headroom
  (Spark added sUSDS in late 2024).
- `SSR_APY > Spark_DAI_borrow_APY` (otherwise loop is anti-yield). PoC reads
  both and warns if inverted.
- DaiUsds wrapper deployed and unpaused.

## Strategy steps

1. Pin fork to **block `21_500_000`** (~late December 2024). At this block:
   - SSR ≈ 11.5%
   - DSR ≈ 7.5%
   - Spark DAI borrow APY ≈ 8%
   - sUSDS LTV in Spark = 0.75
   - Spread `SSR - Spark_borrow ≈ +3.5%`
2. Wrap seed DAI -> USDS via `DaiUsds.daiToUsds(this, daiAmt)`.
3. `sUSDS.deposit(usdsAmt, this)` -> receive sUSDS shares.
4. `Spark.supply(sUSDS, shares, this, 0)`.
5. Loop:
   - `Spark.borrow(DAI, safeFrac * availableBorrowsBase, variableRate, 0, this)`.
   - `DaiUsds.daiToUsds(this, daiOut)` -> USDS.
   - `sUSDS.deposit(usdsOut, this)` -> sUSDS.
   - `Spark.supply(sUSDS, newShares, this, 0)`.
6. Repeat 5 iterations -> ~2.5x leverage.
7. Warp 60 days. Unwind: withdraw sUSDS, redeem to USDS, `usdsToDai`, repay
   Spark.

## PnL math

```
APY_net      = L * SSR_APY - (L - 1) * Spark_DAI_borrow_APY
gross_30d    = SEED * ((1 + APY_net)^(60/365) - 1)
net_30d_DAI  = gross_30d - gas_cost
```

For a $200_000 seed, `L=2.5x`, SSR=11.5%, Spark borrow=8%:
`APY_net = 0.115 + 1.5 * 0.035 = 0.1675 = 16.75%`. Over 60 days:
`200_000 * ((1.1675)^(60/365) - 1) ≈ 200_000 * 0.0258 ≈ $5_160`.

Gas: the 5-iteration loop is ~1.8 M gas (wrap, deposit, supply per turn). At
20 gwei and ETH=$3500 that's ~$126. Net ≈ $5_034 over 60 days, then linear in
seed.

## Block pinned

`21_500_000` — late December 2024. Sky's SSR boost period was active and Spark
had a multi-hundred-bp positive spread vs DAI borrow.

If the pinned block has zero/negative spread (e.g. running on a more recent
block where SSR has converged to DSR), the PoC logs `no_spread` and verifies
seed preservation instead of asserting outsized gain.

## Risks

- **Sky governance can collapse the SSR.** A single spell can equalize SSR and
  DSR, killing the spread.
- **Spark DAI IRM change.** Spark could raise the DAI borrow spread to absorb
  the loop demand, inverting the trade.
- **sUSDS LT change in Spark.** A reduction below the active health factor
  forces a liquidation. PoC stays at 85% of `availableBorrowsBase` for
  safety.
- **DaiUsds wrapper pause.** The wrapper holds the Maker `DAI_JOIN` and the
  USDS `MCD_LITE_PSM`. Sky can pause it for migration spells; entry/exit then
  routes through Curve's USDS/DAI pool with bp-level slippage.
- **Wrapper allowance topology.** `daiToUsds` pulls DAI directly from caller;
  no two-step join. The PoC approves the wrapper.

## Result
Status: theoretical-historical-replay
Expected PnL: ~16.75% APY on equity (~$5,034 net per $200k seed over 60 days at SSR=11.5%, Spark borrow=8%, L=2.5x)

A loop that captures the structural SSR-vs-Spark-borrow spread that only Sky
can offer. PoC asserts: loop leverage > 2.3x, net DAI delta on a 60-day warp
> 0 when spread is positive, full unwind without bad debt.
