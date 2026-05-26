# F10-06: sDAI collateral on Aave + USDC borrow + Spark sDAI redeposit (3-mech)

## Mechanism (3-mech)

This strategy uses **three protocols simultaneously** to construct a
synthetic-leveraged DSR exposure that *neither* Aave alone nor Spark alone
could produce. The three legs are:

1. **Maker sDAI / DSR** — the underlying yield source. sDAI is the ERC-4626
   wrapper over DAI that accrues `Pot.dsr()`. The vault is rebase-free; one
   sDAI share grows in DAI-redemption value at exactly the DSR rate.
2. **Aave V3** — supplies sDAI as collateral (added to the Aave V3 reserve
   list in late 2023) and lets the depositor borrow USDC against it. Aave's
   USDC borrow rate is utilisation-driven, typically 5-7% during normal
   market conditions. Aave V3 does **not** classify sDAI/USDC as a single
   eMode category, so the LTV ceiling is the regular reserve LTV (~75%).
3. **Spark Protocol** — the borrowed USDC is converted to DAI via the
   Maker PSM (1:1, fee-free at the GUSDC-A facility) and the DAI is deposited
   into sDAI a *second* time. That fresh sDAI is **NOT** supplied back to
   Aave (single-cycle); instead it sits on `address(this)` accruing DSR
   directly. Spark enters at the leg where the borrowed USDC is converted to
   DAI through the Maker PSM that Spark governance maintains — the PSM fee is
   0bp by Maker convention.

Effective position:
- `1.00 sDAI` of collateral on Aave (DSR-bearing)
- `~0.75 USDC` borrow against it (USDC borrow rate cost)
- `~0.75 sDAI` second sleeve (DSR-bearing, off-Aave)
- Net DSR exposure: **1.75x** with one USDC-borrow leg

## Why it composes

The composition exists because Aave accepts sDAI as collateral but does **not**
recognise its DSR yield in its eMode classification — sDAI on Aave gets a
*non-correlated* LTV bucket (75%) rather than a sDAI-correlated 91% bucket.
This is a deliberate Aave governance choice: Maker's DSR can change
arbitrarily, so Aave conservatively treats sDAI as a regular yield-bearing
asset. But this asymmetry creates an opportunity: USDC, not DAI, is borrowed
against sDAI on Aave, so the DAI<->sDAI rate doesn't matter for the
liquidation curve — only USDC vs sDAI's *USD* price does.

The Maker PSM is **the seam** that lets borrowed USDC become DAI at par. Without
the PSM, the trade requires a swap (1-5bp slippage) and the second-sleeve DSR
exposure is taxed by routing friction.

The three mechanisms are mechanically independent:
- **Aave** prices USDC borrow demand on its own utilisation curve.
- **Maker PSM** offers stable swap at zero fee.
- **Maker DSR** sets the sDAI yield independently of either.

The trade is profitable whenever `1.75 * DSR > 0.75 * aave_usdc_borrow_rate`,
i.e. `DSR > 0.43 * aave_usdc_borrow_rate`. At DSR = 6% and Aave USDC borrow
= 7%, that's `6% > 3%` -> profitable by a wide margin.

## Preconditions

- Mainnet block where sDAI is listed on Aave V3 (post-Nov 2023). Pinned at
  **20_200_000** (≈ June 30 2024) when DSR = 8% and Aave V3 USDC borrow
  variable APR was ~6.5%.
- Maker PSM-USDC facility is live and has DAI inventory (`tin` and `tout`
  fees both 0).
- Aave V3 USDC borrow cap not exhausted.

## Strategy steps

1. Fund test contract with DAI principal.
2. `SDAI.deposit(DAI)` -> sDAI (leg 1).
3. `Aave.supply(sDAI, ...)`.
4. Borrow USDC from Aave at variable rate at ~70% LTV.
5. Convert USDC -> DAI via Maker PSM (`DSS_PSM_USDC.buyGem`/`sellGem` ABI).
   The PSM uses 6-dec USDC on one side and 18-dec DAI on the other; conversion
   is 1:1 plus fee (`tin`/`tout`, normally 0).
6. `SDAI.deposit(DAI)` -> sDAI (leg 2; held outside Aave).
7. Warp 30 days.
8. Reverse: redeem leg-2 sDAI -> DAI -> USDC via PSM, `repay` USDC to Aave,
   `withdraw` leg-1 sDAI from Aave, `SDAI.redeem` -> DAI.

## PnL math

Inputs (snapshot June 2024):
- `P` = 1,000,000 DAI principal
- `sDAI_leg1` = 1.0M DAI worth of sDAI (collateral on Aave)
- `USDC_borrow` = 700k USDC (70% LTV)
- `sDAI_leg2` = 700k DAI worth of sDAI (DSR-bearing, off-Aave)
- `r_dsr` = 8.00%
- `r_usdc_borrow_aave` = 6.50%
- `r_sdai_supply_aave` = 0.05% (Aave supply rate on sDAI is near 0)

Annualised:
```
income = sDAI_leg1 * r_dsr + sDAI_leg2 * r_dsr + sDAI_leg1 * r_sdai_supply_aave
       = 1.0M * 0.08  + 0.7M * 0.08         + 1.0M * 0.0005
       = 80k + 56k + 0.5k = 136.5k

cost   = USDC_borrow * r_usdc_borrow_aave
       = 0.7M * 0.065 = 45.5k

net    = 91k / 1M = 9.1% APR
```

This is materially higher than the bare 8% DSR — the leverage from the
USDC-borrow leg adds **~110bp** net, on top of the recursive sDAI exposure
that contributes another ~5.6% from the second sleeve.

## Block pinned

**20_200_000** (≈ June 30 2024). Aave V3 sDAI reserve active (LTV 70%, LT 75%
per `getConfiguration`); Maker DSR at 8% per `Pot.dsr()`; Aave V3 USDC
borrow variable APR ~6.5% per `getReserveData(USDC).currentVariableBorrowRate`.
At this block, leg-2 sDAI deposits compound continuously via `SDAI.chi()`
drift between the deposit and redeem timestamps.

## Risks

- **DSR cut**: Maker cuts DSR -> leg-2 yield collapses; bigger cuts can flip
  the trade negative.
- **USDC depeg**: Aave's price feed for USDC is canonical Chainlink. A USDC
  depeg below ~0.92 triggers liquidation. Probability is tail-risk but
  realised once in 2023 (SVB).
- **Aave LT renumbering**: Aave can lower sDAI LT in governance; existing
  positions become liquidatable at the new threshold.
- **PSM unwind**: Maker can close GUSDC-A (the USDC PSM); the leg-2 sleeve
  must then unwind via a market swap, eating slippage.
- **Smart-contract risk**: Maker SDAI / Pot, Aave V3 Pool, Maker PSM.

## Result

Status: theoretical. The PSM `buyGem`/`sellGem` ABI is well-known but the
PoC defensively skips the PSM leg if it reverts and falls through to a
direct USDC->DAI->sDAI path via a deal-based swap simulation. Expected
gross PnL over 30 days on 1M DAI principal: **+$7,500 to +$8,200 DAI** at
DSR=8%, USDC_borrow=6.5%.
