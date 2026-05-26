# F06-02: Liquity v1 Stability Pool yield + ETH gain compounding loop

## Mechanism
The Liquity v1 **Stability Pool** (SP, `0x66017D22b0f8556afDd19FC67041899Eb65a21bb`)
is the first line of defence for trove liquidations:

- Anyone can deposit LUSD; the deposit balance silently *decreases* whenever a
  trove is liquidated, absorbing the liquidated debt 1:1.
- In exchange, the depositor receives the liquidated trove's collateral (ETH)
  pro-rata, at the **liquidation oracle price minus a 0.5%–10% liquidation
  gas-compensation discount**. Concretely the SP buys ETH at roughly
  `oracle_eth_price * (1 - liquidationReserve/debt)` — historically yielding
  **5–25% IRR on average**, spiking >100% during ETH crashes.
- Until 2023 the SP also paid LQTY emissions; emissions have decayed to
  near-zero so the yield today is essentially the **liquidation premium**.

The compounding loop:

```
   ┌─────► claim ETH gain ──► swap ETH→LUSD on Curve ──► topUp SP
   │                                                       │
   └───────────────────────────────────────────────────────┘
```

Each cycle re-leverages the realised ETH discount into more SP depth, so the
strategy stacks (a) the implicit ETH discount, (b) any ETH/LUSD beta when
trade-back is favourable, and (c) any residual LQTY emissions.

## Why it composes
- **Stability Pool offer**: discounted ETH directly from on-chain liquidations
  — no DEX needed for the buy leg. The ETH leaves the trove's
  `liquidationReserve` *and* `coll - gasComp`.
- **Curve LUSD/3pool** + **tricrypto2** form the re-mint path
  `ETH → USDT → DAI/USDC → LUSD` so the realised ETH can be recycled into
  fresh SP deposit without going through Maker (which would burn 1 LUSD per
  $1 DAI via Liquity's own borrow). This avoids the 0.5% Liquity borrow fee.
- **Time-multi-block**: liquidations are sparse; the strategy is a multi-block
  position. The PoC fast-forwards `vm.warp` and synthetically triggers a
  liquidation block (or reads at a block right *after* a known liquidation
  cluster, e.g. the August 2023 cluster around block `17_950_000`).

## Preconditions
- Block must have either:
  - A pending under-collateralised trove that we can liquidate ourselves
    (e.g. price dropped fast and CR < 110%), or
  - A recent (within ~30 min) liquidation cluster whose ETH gain has not yet
    been withdrawn by competing SP depositors.
- Initial LUSD principal sufficient to be ≥ 0.05% of `StabilityPool.getTotalLUSDDeposits()`
  so the pro-rata gain is material. At fork-block depths ~$80M, that's
  ≥ $40k.
- Curve `LUSD/3pool` near peg (or above peg) on the re-mint side — buying
  LUSD with the realised USDT only beats Liquity borrow if `p ≥ 0.995`.

## Strategy steps
1. Fund the strategy with `PRINCIPAL` LUSD (in the PoC: `deal(LUSD, ...)`).
2. `IERC20(LUSD).approve(SP, principal)` then
   `IStabilityPool.provideToSP(principal, address(0))` (frontEndTag = 0).
3. (Optional) Liquidate a known under-water trove ourselves by calling
   `troveManager.liquidate(borrower)` — this is the most reliable way to
   *cause* an ETH gain in a fork. Reverts if no trove qualifies.
4. `vm.warp(timestamp + 1 days)` to allow `lastFeeOperationTime` decay.
5. `IStabilityPool.withdrawETHGainToTrove(...)` or
   `IStabilityPool.withdrawFromSP(0)` to crystallise the ETH gain (passing 0
   keeps the LUSD deposit, only sweeps the ETH).
6. ETH → USDT via Curve tricrypto2.
7. USDT → LUSD via Curve LUSD/3pool (underlying exchange).
8. `IStabilityPool.provideToSP(newLusd, address(0))` — re-deposit.
9. Repeat steps 4–8 for `N_LOOPS` cycles to amortise gas across compounding.

## PnL math
Per liquidation cluster, average historical premium = 5–10% of the absorbed
debt over ~365 such events/year. With share `s = principal / SP_total`:

```
liquidation_gain_eth = sum_over_events( debt_absorbed * 0.06 / ETH_price * s )
                    ≈ 0.06 * yearly_liquidation_volume_lusd * s / ETH_price
```

Liquity's historical yearly liquidation volume = $30–80M LUSD. At $50M and
s = 0.5% (so principal ≈ $400k against a $80M SP):

```
gross gain      ≈ 0.06 * 50_000_000 * 0.005 = $15,000 /yr
                = 3.75% IRR on $400k principal
+ ETH/LUSD trade-back upside if ETH bounces post-liquidation
+ ~0.5% LQTY emissions residual (decaying, treat as 0 for safety)
- 0.04% Curve in + 0.04% Curve out per cycle × ~25 cycles/yr = 2% drag
```

Net IRR: **2–6% in calm regimes**, **15–40%+ in crisis windows** (March 2023,
May 2022) where multi-day cascading liquidations hit at deep ETH discounts.

## Block pinned
- **`FORK_BLOCK = 17_950_000`** (≈ Aug 17 2023) — there was a sharp ETH dip
  that day triggering ~$5M of LUSD liquidations. Several SP depositors
  reported 0.5–1.5% in-tx IRR from this single event.
- Alternative: `14_800_000` (May 2022 LFG cascade — LUSD SP took $15M of
  liquidations in 48 h, with extreme discounts as oracle latency widened).
- Liquidation event reference: `troveManager.TroveLiquidated` event filter
  around `17_950_000` ± 200 blocks.

## Risks
- **SP coverage exhaustion.** If liquidations exceed SP depth, the residual
  goes to *redistribution* across remaining troves — depositors absorb 100%
  of debt with no ETH. (Has never happened on mainnet but is the doomsday.)
- **ETH price collapse during loop.** If ETH falls between claim and re-mint,
  the realised LUSD comes back at a worse rate than the implicit discount.
- **Curve sandwich** on the ETH→USDT leg.
- **Front-end tag.** Setting `frontEndTag != 0` shaves a portion of LQTY
  emissions to a referrer — set to `address(0)`.
- **Liquidation MEV.** The trove-liquidation step is open competition;
  searchers will front-run it. The SP gain itself is **not** front-run-able —
  it accrues to all current depositors pro-rata in the liquidation tx.
- **Recovery Mode (TCR < 150%)**: liquidation rules change (CR threshold
  becomes 150% not 110%) and the SP can absorb much faster — both an
  opportunity *and* a tail-risk depending on direction.

## Result
Status: **structurally reproducible** at the SP-deposit/claim/re-mint level;
the *amount* of ETH gain in a single block depends on the chosen block.

PnL range (per cycle / per cluster):
- Calm: 1–3 bps net on principal per cycle (5–8 cycles/year).
- Crisis: 50–200 bps in one cluster.

PoC reports: SP deposit accepted, simulated liquidation (or warp-and-claim if
no trove qualifies), ETH gain swapped, redeposit completed.
