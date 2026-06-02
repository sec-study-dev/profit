# B14-05: sUSDX (Lista savings) + Pendle PT lock + Venus loop — 3-mechanism stack

## Mechanism (3-mech)
Three independent BSC yield mechanisms stacked on a single USDT principal:

1. **sUSDX — Lista savings wrapper**. ERC-4626-style stablecoin paying a
   real (no token-incentive) ~6 % APR sourced from Lista's reserve-asset
   yield and stability-pool fees. Distinct from `lisUSD` (the CDP-issued
   stable) — sUSDX is the *savings receipt* that captures the carry.
2. **Pendle PT-sUSDX lock**. Buy `PT-sUSDX-26JUN2025` to lock the spot
   savings APR at a small premium (~120 bp) and immunise against rate
   compression. PT trades at ~0.96 USDT so 4-cents-on-the-dollar of pure
   carry is locked over ~6 months.
3. **Venus borrow recycle**. Use PT-sUSDX as collateral in the Venus
   isolated pool (CF ~0.70, lower than vanilla stables due to PT
   discount-rate risk), borrow USDT, redeposit the borrowed USDT into
   sUSDX. The borrow leg also accrues XVS incentive (`~2.5 % APR`)
   which partially offsets the Venus borrow APR.

The three mechanisms are mutually orthogonal: Pendle locks fix-rate
risk, sUSDX produces the underlying yield, and Venus extracts cheap
leverage on the locked PT to multiply the spot carry.

## Why it composes
- PT-sUSDX is a regular ERC-20 once minted, so any Aave-v3-style
  lending market that whitelists it (Venus isolated pool here) treats
  it as standard collateral.
- The savings APR (`SUSDX_APR_BPS = 6 %`) sits above the Venus borrow
  APR (`VENUS_BORROW_APR_BPS = 6 %`) only after the XVS incentive
  bonus, so the loop is **incentive-dependent** — turn it off the loop
  inverts.
- The split (50% spot sUSDX, 50% PT) lets the spot leg compound at
  variable APR while the PT leg locks downside.

## Preconditions
- Pendle BSC market for PT-sUSDX is live with ≥ $2M TVL (so the
  100k USDT entry incurs < 30 bp slippage).
- Venus isolated pool whitelists PT-sUSDX with CF ≥ 0.65.
- sUSDX deposit/withdraw is open (no cooldown enforced inside the
  60-day holding window).

## Strategy steps (100k USDT, 60-day hold)
1. `_fund` 100k USDT.
2. Split: 50k → Pendle PT, 50k → sUSDX direct deposit.
3. Use the PT-sUSDX position as Venus collateral, run 3 borrow-recycle
   loops at CF * SAFETY = 0.63.
4. Hold 60 days; accrue all three legs.
5. Claim XVS via `Comptroller.claimVenus`.
6. PnL = PT carry + sUSDX carry + loop carry − entry drag − recycle drag.

Effective debt leverage from 3 loops at 0.63 step ≈ 1.0×.

## PnL math (100k USDT, 60-day horizon)
- PT leg (50k @ 7.20 %, 60d): `7.20 % × 60/365 × 50k = +592 USD`.
- Spot leg (50k @ 6.00 %, 60d): `6.00 % × 60/365 × 50k = +493 USD`.
- Loop overlay (debt ~ 50k × 1.0 ≈ 50k):
  - Supply side: borrow recycled into sUSDX @ 6.00 %.
  - Borrow side: net `2.5 % − 6.0 % = −3.5 %`.
  - Net: `(6.0 % − 3.5 %) × 50k × 60/365 = +205 USD`.
- One-shot drag: PT entry (50k × 35 bp = `-175 USD`); recycle
  (50k × 20 bp × 1.0 = `-100 USD`).

Total PnL ≈ `592 + 493 + 205 − 175 − 100 = +1,015 USD ≈ +1.02 %`
on 100k over 60 days (~6.2 % annualised — well above static sUSDX).

Gas: ~3M gas × 1 gwei × $600/BNB ≈ `$1.8` — negligible.

## Block pinned
**42_500_000** (late-2024). Re-pin once BSC RPC + Pendle BSC PT-sUSDX
market are verified.

## Addresses used
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Venus Comptroller.
- `0xfD5840Cd36d94D7229439859C0112a4185BC0255` — vUSDT (used here as
  the recycle anchor; the real strategy would use the isolated PT-sUSDX
  vToken once listed).
- `0x888888888889758F76e7103c6CbF23ABbF58F946` — Pendle Router V4.
- `LOCAL_SUSDX` (`0x...B14051`) — sUSDX wrapper placeholder; replace
  with canonical Lista sUSDX once on BscScan.
- `LOCAL_PT_SUSDX_MARKET` / `LOCAL_PT_SUSDX` — Pendle market + PT
  placeholders.

## Risks
- **Pendle PT discount widening**: PT-sUSDX trading down to $0.92 mid-life
  marks the PT leg `-3 %` MTM. Hold-to-maturity neutralises it; the
  60-day projection is short enough to absorb MTM noise via convergence.
- **Venus CF cut on PT**: governance can cut CF if the PT discount
  rate spikes. Loop unwind is bounded by sUSDX redeem (instant).
- **sUSDX redeem cap**: if Lista enforces a withdraw cap during stress
  the spot leg can be stuck for a few days. PnL accrues but the exit
  is delayed.
- **XVS halt on isolated pool**: the loop carry collapses to
  `−3.5 % × 50k × 60/365 ≈ −287 USD`. Net PnL would still be
  positive (~+523 USD).

## Result
Status: **theoretical** — BSC RPC + Pendle PT-sUSDX BSC market not
yet verified. Expected PnL: **+1.0 % over 60 days on 100k USDT
principal**, decomposed as 58 % from the Pendle PT lock, 28 % from
spot sUSDX, 14 % from the leveraged borrow recycle.

## TODO
- Verify `LOCAL_SUSDX`, `LOCAL_PT_SUSDX_MARKET`, `LOCAL_PT_SUSDX`,
  `LOCAL_XVS` against BscScan / Pendle subgraph.
- Re-pin block once the Pendle PT-sUSDX market is verified live.
- Swap `vUSDT` collateral anchor for the canonical Venus isolated-pool
  vToken for PT-sUSDX once listed.
