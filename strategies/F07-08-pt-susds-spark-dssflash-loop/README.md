# F07-08: PT-sUSDS + Spark + DssFlash bootstrap (Pendle + Morpho/Spark + Maker)

## Mechanism (3-mechanism)
1. **Pendle PT-sUSDS-25SEP2025** — fixed-discount zero-coupon claim on
   1 sUSDS at maturity. sUSDS itself is Sky's ERC-4626 vault over USDS,
   accreting the Sky Savings Rate (SSR, currently ~6.5% APY). Implied PT
   discount at issuance was ~7-9% APY (modest because SSR is itself
   modest).
2. **Morpho Blue PT-sUSDS/USDS market** — Spark-curated isolated market
   with `PendleSparkLinearDiscount` oracle, 91.5% LLTV (higher than the
   86.5% PT-sUSDe variant because sUSDS/USDS peg is on-protocol and
   doesn't carry the Ethena hedge risk).
3. **MakerDAO DSS Flash mint + Sky DAI↔USDS converter** — DssFlash mints
   DAI free of premium (`toll = 0`) on demand up to `max()` (currently
   500M DAI). The Sky 1:1 DAI↔USDS converter (Sky's post-rebrand bridge)
   lets us shuttle flashed DAI into USDS with zero slippage. The flash
   leg eliminates the multi-loop incremental supply/borrow ramp and
   bootstraps the position to its full target leverage in a single
   transaction.

Composition: convert equity USDS → DAI (just so DAI and flashed DAI can
share an account); flash-mint `3M DAI`; inside the callback, convert
DAI → USDS via the converter (gives 4M USDS total at the same moment);
buy `~4.2M PT-sUSDS` on Pendle; supply all PT to Morpho; borrow 3M USDS;
convert USDS → DAI; repay DssFlash. Final position: `~4.2M PT-sUSDS`
collateral against `3M USDS` debt, on `1M USDS` equity = K≈4.

## Why it composes
This is a 3-mechanism extension of F07-01 where the **third mechanism is
the funding bootstrap** (DssFlash) rather than an exotic collateral or
borrow asset. The benefits:
- **Atomic leverage entry**: no need to do 4 sequential supply/borrow/buy
  loops; the entire position is established in a single transaction. This
  removes inter-loop oracle drift and reduces gas substantially
  (~600k gas vs. ~1.6M for the equivalent 4-loop variant).
- **Zero flash fee**: DssFlash toll = 0 at the time of writing
  (Maker/Sky governance can set non-zero but historically has not).
- **Higher LLTV (91.5%)**: the Spark-curated PT-sUSDS/USDS market is more
  permissive than PT-sUSDe variants because the peg risk is lower.

The composition trades off:
- **Larger DssFlash dependency**: a single tx fails if DAI flash mint
  cap is reduced or if the converter is paused.
- **Single-block AMM impact**: buying 4M PT-sUSDS in one tx hits AMM
  slippage harder than spreading over 4 loops (mitigated by Pendle's
  PT-sUSDS market depth, $20-50M TVL historically).

## Preconditions
- Fork block before PT-sUSDS-25SEP2025 maturity.
- DssFlash `max()` ≥ `FLASH_DAI` (3M DAI) — currently 500M cap.
- Sky DAI↔USDS converter operational (default state since rebrand).
- Pendle PT-sUSDS AMM has ≥ 4M USDS-side liquidity at the buy size.
- Morpho PT-sUSDS/USDS market has ≥ 3M USDS supply.

## Strategy steps
1. Acquire `1M USDS` equity.
2. Approve DssFlash, the DAI↔USDS converter, Pendle Router V4, Morpho.
3. Convert `1M USDS → 1M DAI` via Sky converter (bridging step).
4. Call `DssFlash.flashLoan(this, DAI, 3M, "")`.
5. In `onFlashLoan` callback:
   - Total DAI = 4M (1M equity + 3M flashed).
   - DAI → USDS via converter: 4M USDS.
   - Buy PT-sUSDS with all 4M USDS → ~4.2M PT (at 0.95 implied discount).
   - Supply all PT to Morpho PT-sUSDS/USDS market.
   - Borrow 3M USDS from Morpho.
   - USDS → DAI via converter: 3M DAI.
   - Approve DssFlash for 3M DAI repay.
6. Return ERC-3156 magic value; DssFlash pulls 3M DAI back.
7. (Exit conceptual) Maturity: PT → sUSDe via `redeemPyToToken` → repay
   Morpho USDS debt; withdraw PT collateral; convert residual.

## PnL math
Let:
- `P_buy`  = PT-sUSDS spot ≈ 0.945 USDS (Nov 2024 quote for ~10mo maturity)
- `P_mat`  = 1.0 sUSDS at maturity = 1.0 × (1 + SSR * 10/12) ≈ 1.054 USDS-
             equivalent of value at maturity (sUSDS shares appreciate vs USDS)
- `t`      = 320 / 365 ≈ 0.877 years
- `r_pt`   = (1.054 / 0.945 − 1) / 0.877 ≈ 13.1% APY implied fixed
- `r_b`    = USDS borrow APY on Morpho PT-sUSDS/USDS market ≈ 5.0-6.0%
- `L`      = 0.875 effective LTV (under 91.5% LLTV)
- `K`      = 1 / (1 − L) = 8.0

Net APY on equity (USDS-denominated):
```
net_apy = K * r_pt − (K − 1) * r_borrow
        = 8.0 * 0.131 − 7.0 * 0.055
        = 1.048 − 0.385
        = 0.663   (~66% APY in USDS)
```

Apply realistic frictions:
- Pendle AMM impact ~50 bps on a single 4M-USDS buy (vs spread-out loops):
  -0.5% one-time = -0.6% on equity.
- DssFlash gas: ~1.2M gas on the bootstrap tx, immaterial at 30 gwei.
- Morpho curator share ~10%.

Realistic **~50-58% APY in USDS terms** over the 320-day window, i.e.
~44-51% absolute return on 1M USDS equity (~$440-510k after USDS≈USD).

Capacity: bounded by DssFlash cap (500M) and PT-sUSDS AMM depth (~50M).
Capacity for this PoC structure: ~$10-25M before AMM impact dominates.

## Block pinned
**21_050_000** (~Nov 3 2024). PT-sUSDS-25SEP2025 has ~10 months to maturity,
Sky DAI↔USDS converter operational, Morpho PT-sUSDS/USDS market live with
the 91.5% LLTV variant, DssFlash cap intact.

## Risks
- **DssFlash governance change**: Maker/Sky can set a non-zero toll (the
  ERC-3156 fee parameter). At 5-10 bps the strategy still wins; at >25 bps
  the bootstrap dominates and the simple-loop variant becomes preferable.
- **Sky DAI↔USDS converter pause**. The converter is governance-pausable;
  if paused, the flash leg fails and the strategy reverts. Fallback path:
  use the PSM (USDC ↔ DAI via DSS_PSM_USDC, 0-0.5 bps) and skip the USDS
  rail — but then loan token of Morpho PT-sUSDS/USDS market is USDS not
  USDC, so a Curve USDS/USDC swap is needed.
- **sUSDS NAV drop**. sUSDS is essentially USDS × (1 + SSR × t); the only
  way NAV drops is if Maker reduces SSR retroactively (not possible on
  past accruals) or if a Maker reserve event triggers PSM closure.
- **Morpho curator withdraws USDS supply**. Borrow APY ramps under
  AdaptiveCurve IRM; if APY > PT implied APY, the carry inverts. Spark
  is the curator here and typically maintains adequate supply.
- **Pendle V4 router / SY-sUSDS bug**.

## Result
Status: theoretical. PoC source establishes the full leveraged position
in a single transaction inside the `onFlashLoan` callback. Expected PnL
on 1M USDS equity at K≈8 (the 91.5% LLTV market enables a higher K than
the 86%-LLTV variants): **+$440-510k USDS absolute** over the 320-day
window in USDS terms (≈USD equivalent), gross of gas and tail re-pegging
risk.
