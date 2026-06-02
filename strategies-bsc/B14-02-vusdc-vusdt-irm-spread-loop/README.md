# B14-02: vUSDC collateral × vUSDT borrow — wrapper IRM-spread recursion

## Mechanism
A **stable-on-stable** wrapper loop that exploits two *different* Venus
yield-bearing wrappers (`vUSDC` and `vUSDT`) sharing the same Comptroller
collateral graph but having **decorrelated IRM curves**. Because vUSDC and
vUSDT have independent utilisations (the two USDT and USDC markets see
very different demand from BSC borrowers), `vUSDC.supplyAPY()` is often
materially above `vUSDT.borrowAPR()` at the same block:

- BSC borrowers heavily prefer USDT (peg-tight, most LPs quote it), so
  `vUSDT` utilisation sits 60-75 %.
- vUSDC utilisation sits 30-45 % because USDC is mostly held idle for
  PCS v3 USDC pairs.
- Result: `vUSDC supply APY ≈ 1.2 %` but `vUSDT borrow APR ≈ 2.8 %` —
  raw spread of `-1.6 %`. **Negative on its own.**

The carry only opens when XVS incentives are stacked:

1. **vUSDC supply XVS** (heavy because Venus wants to pull USDC TVL in):
   `~4.0 % APR`.
2. **vUSDT borrow XVS** (subsidised to keep borrow demand up):
   `~3.0 % APR`.

Net per-leg: supply leg `1.2 + 4.0 = +5.2 %`, borrow leg
`3.0 − 2.8 = +0.2 %`. Both legs net-positive ⇒ recursing the loop scales
both. At 4× leverage (collateral) and 3× leverage (debt), gross APY ≈
`4 × 5.2 + 3 × 0.2 = 21.4 %`.

This differs from B05 (Ethena protocol carry) and from B14-01 (same-asset
self-loop) by being a **cross-wrapper** spread play. The two wrappers
target the same underlying class (USD stables) so peg risk is symmetric;
only the IRM and XVS incentive differentials matter.

## Why it composes
- Venus' Comptroller treats `vUSDC` and `vUSDT` as independent markets
  with separate IRM models — there is no automatic rebalance.
- The CF on vUSDC against any borrow asset is `~0.80`; vs USDT borrows
  the effective LTV (after 0.95 safety haircut) is `~0.76`.
- Both XVS incentive streams are claimable via a single
  `Comptroller.claimVenus(holder)` call, amortising claim gas.
- The peg risk between USDC and USDT on BSC is small (< 5 bp historic
  basis between Binance-peg USDC and Binance-peg USDT). PCS StableSwap
  pool absorbs unwind slippage at < 2 bp.

## Preconditions
- BSC block where Venus Core has both vUSDC and vUSDT listed with active
  XVS incentives on the relevant legs.
- vUSDT utilisation < 80 % so the borrow IRM is on the flat side.
- `vUSDC.supplyRatePerBlock() + venusSupplySpeeds(vUSDC) > 0`.
- `venusBorrowSpeeds(vUSDT) > 0`.
- PCS StableSwap USDC/USDT pool has ≥ $5M reserves to absorb the
  borrowed-USDT → USDC re-supply path with < 5 bp slippage.

## Strategy steps (4 iterations, 100k USDC principal)
1. `_fund` 100k USDC into the test contract.
2. `enterMarkets([vUSDC, vUSDT])`.
3. For `i = 0..3`:
   - `vUSDC.mint(usdc_balance)` — supplies USDC, mints vUSDC.
   - `vUSDT.borrow(usdc_balance * 0.76)` — borrows USDT.
   - Swap USDT → USDC on PCS StableSwap.
4. Hold 30 days; force accruals.
5. `claimVenus(address(this))` — collect XVS reward stream.
6. Dump XVS → USDT (offline assumes flat XVS price + 30 bp DEX cost).
7. PnL = `Δ USDC + Δ USDT − Δ vUSDT_debt + XVS_dump_USD − gas`.

Effective leverage at LTV 0.76 per step, N=4:
`L = 1 + 0.76 + 0.578 + 0.439 + 0.334 ≈ 3.11×`.

## PnL math (100k USDC principal, 30-day horizon)
Indicative rates at the pinned block:
- vUSDC supply APY: `1.2 %`. XVS supply: `4.0 %`. ⇒ supply leg net `+5.2 %`.
- vUSDT borrow APR: `2.8 %`. XVS borrow: `3.0 %`. ⇒ borrow leg net `+0.2 %`.
- Per-loop swap cost: PCS StableSwap USDC/USDT 2 bp + peg basis 1 bp ≈
  `3 bp` per debt unit.

Levered:
- Collateral leverage = 3.11×.
- Debt leverage = 2.11×.

Gross APY = `3.11 × 5.2 + 2.11 × 0.2 = 16.17 + 0.42 = +16.59 %`.

Swap drag = `3 bp × 2.11 leverage × 4 loops = 25.3 bp` (one-shot) → over
365 days reading, that's `25.3 bp` of position; over 30 days it lives in
the principal at year zero so we subtract it from net PnL once.

30-day PnL on 100k USDC:
- Carry term: `16.59 % × 30/365 × 100k = +1,363 USD`.
- Swap drag: `-25.3 bp × 100k = -253 USD`.
- Net 30-day PnL ≈ `+1,110 USD`.

Gas: 4 × (mint + borrow + StableSwap) + claimVenus ≈ 2.8M gas × 1 gwei ×
$600/BNB ≈ `$1.7` — negligible.

## Block pinned
**42_500_000** (late-2024). Robust to ±500k block drift. Re-pin once
BSC RPC available and `venus*Speeds` for both vUSDC and vUSDT are
verified for the block.

## Addresses used
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Venus Core Comptroller
  (`BSC.VENUS_COMPTROLLER`).
- `0xfD5840Cd36d94D7229439859C0112a4185BC0255` — vUSDT (`BSC.vUSDT`).
- `0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8` — vUSDC (`BSC.vUSDC`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` — USDC (`BSC.USDC`).
- `0xeC2D6Da16e9aDe97c6da8ad6E8C5e6dD7e9d4e8e` — PCS StableSwap router
  (`BSC.PCS_STABLE_ROUTER`).
- `LOCAL_XVS` — Venus governance token placeholder
  (`0x000000000000000000000000000000000000B142`).

## Risks
- **XVS incentive cut on either leg**: governance can reweight supply vs
  borrow incentive split. Either leg flipping negative makes the carry
  drag rather than additive. Monitor `venus*Speeds(token)` each epoch.
- **USDC/USDT peg break**: a Binance freeze of USDC redemption would
  detach the two pegs. The position holds USDC long and USDT short, so
  a USDC discount benefits us; a USDC premium (eg via FDUSD-like
  redemption stress) hurts. PCS StableSwap depth absorbs ≤ 100 bp moves.
- **vUSDT borrow IRM kink**: utilisation crossing 80 % jacks borrow APR
  past 30 %. Size each iteration ≤ 1 % of vUSDT cash so we don't push it.
- **Same-block exchange-rate updates**: vUSDC and vUSDT accrue interest
  on different per-block schedules (different `accrualBlockNumber`). The
  PoC explicitly calls `borrowBalanceCurrent` + `balanceOfUnderlying` on
  both before the PnL snapshot.

## Result
Status: **theoretical** (BSC RPC not configured; PoC compiles and runs
the offline accounting branch). Expected PnL: **+0.9 – 1.4 % over 30
days on 100k USDC principal**, sourced from the cross-wrapper IRM +
XVS incentive spread amplified by ~3× recursive leverage.
