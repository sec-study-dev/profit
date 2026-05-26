# F07-09: YT-pufETH point speculation + PT in Symbiotic vault (Puffer + Pendle + Symbiotic)

## Mechanism (3-mechanism)
1. **Puffer pufETH** — restaked-ETH LRT operating opt-in Anti-Slashing
   (AVS) duties through Puffer's NoOp network. pufETH/ETH NAV appreciates
   with native ETH staking yield AND Puffer accrues two off-chain point
   streams: **Puffer points** (governance speculation pre-PUFFER TGE) and
   **EigenLayer restaking points** (delegated through Puffer's AVS).
2. **Pendle PT/YT-pufETH-26DEC2024 split** — splits pufETH yield into a
   fixed-discount PT (zero-coupon claim on 1 pufETH at maturity) and a
   long-only YT (entire pufETH yield + ALL point streams accrue to YT
   holders until expiry). At trade time, YT-pufETH spot ≈ 0.04 pufETH/YT,
   meaning $1 of YT controls ~25 pufETH-worth of point exposure.
3. **Symbiotic pufETH vault** — Symbiotic is a parallel shared-security
   protocol to EigenLayer. Their pufETH vault accepts pufETH (or, where
   the vault adapter is wired, PT-pufETH) as deposit collateral, paying
   **Symbiotic points** on top of whatever points the underlying already
   accrues. This is "restake on restake on restake" — pufETH already
   delegates ETH to EigenLayer; Symbiotic delegates pufETH to AVS networks
   in a separate security plane.

Composition: split equity 70/30. With the 70% leg, buy YT-pufETH directly
on Pendle for maximum point-per-dollar density. With the 30% leg, use
`mintPyFromToken` (Pendle's split helper) to convert WETH → SY → PT + YT
(1:1); keep both halves: the freshly-minted YT stacks on top of the YT
leg (more points), and the PT is deposited into the Symbiotic pufETH
vault (extra Symbiotic-point stream PLUS the deterministic PT redemption
floor at maturity for the deposited principal).

Net aggregate stream from `100 WETH` equity:
- ~3,000 YT-pufETH (= 3,000 pufETH-worth of Puffer + EL points until expiry)
- ~30 PT-pufETH locked in Symbiotic vault (= 30 pufETH-worth of Symbiotic
  points + 30 pufETH redemption value at maturity)

## Why it composes
This is the cleanest 3-mechanism Pendle composition because each leg
independently amplifies a different reward stream from the SAME underlying:
- **Pendle YT** strips the time-decaying yield/point claim from the
  capital claim, giving max leverage on the off-chain point stream per
  dollar of cash burned.
- **Pendle PT** strips the capital claim (zero-coupon principal); when
  re-deposited in Symbiotic, the principal STILL EARNS POINTS — just from
  a different protocol (Symbiotic, not Puffer/EL). One unit of capital
  earns 3 protocols' points simultaneously.
- **Symbiotic** is a re-hypothecation venue that accepts the now-locked
  PT-pufETH (or its underlying pufETH after redemption) without the LP
  giving up Pendle exposure.

The 70/30 split is tuned to capture maximum YT point density (the
high-IRR leg) while still planting a defensive PT-anchored claim in
Symbiotic that pays out at maturity regardless of how points crystallise.

## Preconditions
- Fork block before PT/YT-pufETH-26DEC2024 maturity.
- Pendle YT-pufETH AMM has sufficient WETH-side liquidity (≥ 5k WETH
  historical Pendle TVL for pufETH markets).
- Symbiotic pufETH vault has remaining capacity (vault caps were ramping
  through Q3-2024; verify before deposit).
- Off-chain assumption: post-TGE point values are >0. Cash PnL is
  negative on the YT leg if points value to zero.

## Strategy steps
1. Acquire `100 WETH` equity.
2. Approve Pendle Router V4 to pull WETH.
3. Compute split: `ytLeg = 70 WETH`, `ptLeg = 30 WETH`.
4. `swapExactTokenForYt(market=YT-pufETH-26DEC2024)` with 70 WETH →
   receive ~2,100 YT (at YT/SY price ~3.3%).
5. `mintPyFromToken(YT, 30 WETH)` → receive ~30 PT-pufETH + ~30 YT-pufETH
   (1:1 from 30 WETH worth of SY).
6. Approve PT to Symbiotic vault; `Symbiotic.deposit(this, ptAmount)`.
   - On failure (PT not accepted by vault adapter): fall back to
     `YT.redeemPY` on the 30/30 PT/YT pair → 30 SY → 30 pufETH →
     deposit 30 pufETH into Symbiotic vault directly.
7. Hold ~150 days (just before maturity). Periodically call
   `YT.redeemDueInterestAndRewards` to crystallise on-chain SY interest
   accrual (Puffer/EL/Symbiotic points are off-chain and reported
   separately).

## PnL math
The trade has TWO PnL channels that have to be added externally:

### A. On-chain cash PnL (denominated in pufETH/WETH)
The YT leg structurally decays to zero at maturity; only the SY-interest
component (the implied yield baked into pufETH NAV) is on-chain.
- `r_pufeth_nav` = pufETH/ETH yield rate ≈ 3.0-3.5% APY
- `t`            = 0.41 years (150 days)
- on-chain SY interest crystallised over t ≈ 70 * 0.41 * 0.033 ≈ 0.95 WETH
- PT leg in Symbiotic: PT redemption value at maturity = 1.0 pufETH each,
  i.e. 30 PT × (1.0 pufETH/PT × ~1.013 ETH/pufETH at maturity) − 30 WETH
  initial cost ≈ +0.4 WETH (PT's fixed-discount gain).

Net on-chain cash PnL ≈ +1.35 WETH on 100 WETH equity = +1.35% absolute.
This is **NEGATIVE-ish in cash terms** because the YT leg dominates and
is structurally decaying — the cash trade is bad without points.

### B. Off-chain point PnL
At trade time the YT controls ~2,100 pufETH-equivalent of point streams
(Puffer + EL points), accrued daily over 0.41 years. Historically pufETH
accrues ~1 Puffer point + ~0.7 EigenLayer points per pufETH per day.
- Puffer points crystallised  = 2,100 * 150 * 1   = 315,000 PUF points
- EL points crystallised      = 2,100 * 150 * 0.7 = 220,500 EL points

Symbiotic vault leg (30 PT-pufETH or 30 pufETH equivalent in vault):
- Symbiotic points ≈ 30 * 150 * 2 (Symbiotic emits at ~2 pt/pufETH/day) =
  9,000 SYM points (additive to Puffer/EL points already on the deposit).

Conservative TGE point pricing assumptions:
- Puffer points → $0.05/PUF point post-TGE
- EigenLayer points → $0.20/EL point post-TGE
- Symbiotic points → $0.30/SYM point post-TGE (smaller program)

Total point value:
- Puffer:    315,000 * $0.05 = $15,750
- EL:        220,500 * $0.20 = $44,100
- Symbiotic:   9,000 * $0.30 =  $2,700
- TOTAL ~       $62,550

On 100 WETH equity (≈ $250k @ $2,500/ETH), point PnL ≈ **+25% absolute
return over 5 months** purely from off-chain TGE realisation. Adding the
~+1.35% on-chain cash → **~26% absolute** total return over the holding
window (≈ 70% APY annualised).

### Sensitivity
The whole thesis lives or dies on point cash values. At half of these
assumptions ($0.025/PUF, $0.10/EL, $0.15/SYM), absolute return drops to
~13%. At zero post-TGE point realisation, the trade returns +1.35%
(barely positive). Risk-adjusted, this is essentially a long-vol bet on
point program success.

## Block pinned
**20_650_000** (~Aug 14 2024). PT/YT-pufETH-26DEC2024 has ~4.5 months to
maturity, YT trading at ~3.3% of SY, Symbiotic pufETH vault accepting
deposits with remaining capacity.

## Risks
- **YT decays to zero**. The YT leg is structurally a long-only point/
  yield claim; cash value at maturity = 0. Entire YT cost is at risk if
  points realise at < entry-implied cost.
- **Symbiotic vault cap exhausted before deposit**. Vault caps were
  binding through Q3-2024; PoC's fallback path is to deposit pufETH
  (post PT/YT-redeem at expiry) instead of PT.
- **pufETH NAV slash / Puffer protocol incident**. Both PT and YT
  redemption values fall proportionally.
- **Restaking program changes / point dilution**. Puffer, EigenLayer,
  and Symbiotic can each unilaterally adjust point multipliers or
  cancel future emissions.
- **Smart-contract risk**: Pendle V4 router, Puffer deposit pool,
  Symbiotic vault registry — three independent codebases.

## Result
Status: theoretical. PoC source establishes both legs (YT bought via
swap, PT minted via `mintPyFromToken`, PT deposited to Symbiotic with
pufETH-fallback). Expected PnL on 100 WETH equity:
- On-chain cash: **+1.0 to +1.5 WETH** (~$2.5-3.8k) on the SY-interest
  accrual leg.
- Off-chain points: **+$60-65k** at central-case TGE assumptions.
- Total absolute: **~+25% return over 150 days** (≈ 70% APY annualised).

The trade is a 3-mechanism "point factory" rather than a fixed-income
carry; it lives or dies on point monetisation but uses every piece of
Pendle's PT/YT machinery in concert with two restaking venues.
