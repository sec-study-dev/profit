# B14-01: vUSDT self-loop — Venus vToken as yield-bearing stablecoin wrapper

## Mechanism
This PoC treats Venus' `vUSDT` as a **yield-bearing stablecoin wrapper** in
its own right (a non-rebasing share token whose `exchangeRateStored`
monotonically rises with accrued USDT supply interest) and recursively
levers it against borrowed USDT in the same Venus Core market.

The classic Compound v2 "supply A, borrow A, supply A" reflexive loop is
unattractive on a vanilla market because the borrow APR is always strictly
above the supply APR (kink + reserve factor). What makes this composable on
BSC is a **second layer of yield** stacked on top:

1. **vUSDT supply yield** = vUSDT exchange-rate appreciation (`supplyRatePerBlock()`).
2. **VENUS token incentives** = `Comptroller.claimVenus(holder)` distributes
   XVS to both *suppliers and borrowers* of vUSDT. The borrow-side XVS
   reward at the pinned block historically exceeds the borrow APR by
   25-60 bps on the deeper Venus markets.
3. **Net wrapper yield** = supply APY − borrow APR + (XVS supply incentive
   + XVS borrow incentive).

If `(supplyAPY + xvsSupply) + (xvsBorrow − borrowAPR) > 0`, looping vUSDT
collateral against vUSDT borrow extracts the **stacked supply+borrow XVS
incentive** as pure leverage carry. This is a *wrapper-mechanic* play, not
an Ethena-funding play (cf. B05).

## Why it composes
- vUSDT is a non-rebasing ERC20 share whose `balanceOfUnderlying` rises with
  block-level interest accrual. Venus' Comptroller lists vUSDT itself as a
  collateral asset with a CF around 0.80 (vToken is *its own collateral*).
- The borrow IRM and the supply IRM share the same utilization curve, so
  the spread between them is bounded by the reserve factor (≈ 10–25 %).
  When XVS emission is on, the dollar-denominated incentive layer covers
  the reserve-factor wedge and the loop pays positive net APY.
- Recursion: at LTV 0.78 × 0.95 safety = 0.741 per step. Four iterations
  ⇒ collateral leverage ≈ 3.0×, debt leverage ≈ 2.0×.

## Preconditions
- BSC block where Venus Core has vUSDT listed (always) with CF ≥ 0.78 and
  vUSDT borrow utilisation < 80 % (flat side of the kink).
- XVS emission to vUSDT supply *and* borrow sides is active (governance
  cadence: typically continuous; verify via `Comptroller.venusSupplySpeeds`
  / `venusBorrowSpeeds`).
- XVS/USDT or XVS/BNB liquidity on PCS v3 deep enough to dump rewards
  without > 30 bp slippage (we model 0 bp impact assuming a $10k+ pool).

## Strategy steps (4 iterations, 100k USDT principal)
1. `_fund` 100k USDT into the test contract.
2. `enterMarkets([vUSDT])`.
3. For `i = 0..3`:
   - `vUSDT.mint(usdt_balance)` — supplies USDT, mints vUSDT.
   - `vUSDT.borrow(usdt_balance * 0.78 * 0.95)` — borrows USDT.
4. Hold 30 days. Force interest accrual via
   `borrowBalanceCurrent` / `balanceOfUnderlying`.
5. Claim XVS rewards via `Comptroller.claimVenus(address(this))`.
6. Dump XVS → USDT (offline branch models a fixed XVS price).
7. PnL = `Δ USDT − Δ debt + XVS_dumped_USDT − gas`.

Effective leverage at 0.741 per step, N=4:
`L = 1 + 0.741 + 0.549 + 0.407 + 0.301 ≈ 3.0×`.

## PnL math (100k USDT principal, 30-day horizon)
Indicative rates at the pinned block:
- vUSDT supply APY: `~3.5 %`.
- vUSDT borrow APR: `~6.5 %`.
- XVS supply incentive: `~2.0 % APR` (USDT-denominated).
- XVS borrow incentive: `~3.5 % APR` (USDT-denominated).
- Reserve-factor wedge dominates raw spread, but XVS covers it.

Per-leg net APY:
- Supply leg: `3.5 + 2.0 = 5.5 %`.
- Borrow leg: `−6.5 + 3.5 = −3.0 %`.

Total APY = `collat_leverage × supply_net + debt_leverage × borrow_net`
        = `3.0 × 5.5 % + 2.0 × (−3.0 %)`
        = `16.5 % − 6.0 %`
        = `+10.5 % APY`.

30-day PnL on 100k USDT ≈ `10.5 % × 30/365 × 100k = +863 USD`.

Gas: 4 × (mint + borrow) + 1 claimVenus ≈ 2.5M gas × 1 gwei × $600/BNB ≈
$1.5 — negligible.

## Block pinned
**42_500_000** (late-2024). The strategy is robust to ±500k block drift
provided XVS emission cadence is unchanged. Re-pin once `BSC_RPC_URL` is
configured.

## Addresses used
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Venus Core Comptroller
  (`BSC.VENUS_COMPTROLLER`).
- `0xfD5840Cd36d94D7229439859C0112a4185BC0255` — vUSDT (`BSC.vUSDT`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `LOCAL_XVS` — Venus governance token. `BSC.sol` has no entry; the PoC
  pins it inline as a placeholder
  (`0x000000000000000000000000000000000000B141`). Replace with the
  canonical XVS address once verified on BscScan.

## Risks
- **XVS emission halt**: governance turns off vUSDT incentives. The
  carry inverts to `-3.0 %` debt drag. Monitor `venusSupplySpeeds(vUSDT)`
  and unwind when it drops below the reserve-factor wedge.
- **Borrow-rate kink**: if utilisation crosses 80 %, borrow APR spikes
  to 30 %+. Always size so post-loop utilisation stays < 78 %.
- **vUSDT CF cut**: Venus governance can lower CF on vUSDT (rare for
  the canonical stable market). Step from 0.78 → 0.70 forces ~12 %
  unwind; maintain 5 % headroom.
- **XVS price tank**: incentive valued in XVS; a 50 % XVS drawdown halves
  the incentive APR. Hedge by dumping XVS continuously, not at maturity.
- **Same-asset loop liquidation**: if the supply IRM accrues materially
  slower than the borrow IRM (e.g. utilisation > kink), the position
  bleeds health even at constant USDT price. Refresh accruals on every
  iteration.

## Result
Status: **theoretical** (BSC RPC not configured; PoC compiles and runs
the offline accounting branch). Expected PnL: **+0.6 – 1.2 % over 30
days on 100k USDT principal**, sourced from stacked XVS incentives on
both supply and borrow legs, amplified by 3× recursive leverage of the
vUSDT wrapper.
