# B06-08: Venus LST isolated pool — WBETH/WETH eMode-style loop

## Family
B06 — Venus V4 isolated pool arbitrage. The LST pool tags WBETH and
bridged WETH as ETH-correlated assets, giving them a structurally
higher collateralFactor against each other than the Core pool's
cross-asset CF. This is the BSC analogue of Aave's eMode and lets a
WBETH supplier ladder up to ~10× effective leverage.

## Mechanism
1. **LST-pool listing of both WBETH and WETH.** Same Comptroller, both
   ETH-priced, both ETH-correlated → CF up to ~90 %.
2. **Recursive supply→borrow loop.** Each iteration supplies WBETH,
   borrows WETH at SAFETY_BPS of liquidity, and re-stakes the WETH
   into WBETH (via `WBETH.deposit{value: 0}(referral)` after a
   `WETH.withdraw` step in production; this PoC soft-falls back to
   a 1:1 swap representation).
3. **Hold to harvest WBETH staking yield − WETH borrow APR.** The
   spread between WBETH's accrued ETH yield (≈ 3.5 % APR) and the
   LST-pool WETH borrow APR (≈ 1.8 % APR — structurally low because
   nobody wants to short WBETH) is the carry.

## Why this is family-distinct
- B06-03 loops slisBNB/BNB through the same Comptroller — but ETH-
  correlated risk groups carry a *different* CF and a *different*
  oracle policy. Two PoCs to validate the IRM topology cover both
  the BNB and ETH-correlated trees.
- The Core pool has WBETH listed against USDT (~75 % CF), not against
  WETH. Migrating to the LST pool unlocks ~15 % more CF per dollar of
  WBETH, which compounds into ~3× more effective notional after 5
  loops.

## Addresses (inlined)
- `LOCAL_LST_COMPTROLLER = 0x596B11ac…` — LST-pool Comptroller. TODO verify.
- `LOCAL_VWBETH_LST = 0x4D41a36D…` — LST-pool vWBETH. TODO verify.
- `LOCAL_VWETH_LST = 0x39E1Da2A…` — LST-pool vWETH. TODO verify.
- `BSC.WBETH`, `BSC.WETH` from the address book.

## Block pinned
**42_500_000** — same as the B06 family. Assumes WBETH/WETH listings are
live on the LST pool by this block; if not, the test prints a clean
no-op PnL.

## PnL math (per 100 WBETH ≈ $300k, 30-day hold, 5 loops, 90 % CF)
- Effective long WBETH notional after 5 loops at 90 % LTV:
  `100 / (1 − 0.9 × 0.95) ≈ 700 WBETH` ≈ $2.1M.
- WBETH ETH staking yield ≈ 3.5 % APR → 30-day on $2.1M = $6,041.
- WETH borrow APR ≈ 1.8 %, debt ≈ $1.8M → 30-day = $2,663.
- LST-pool WBETH supply APY (interest income) ≈ 0.5 % APR ≈ $863.
- **Net 30-day ≈ $4,241 on $300k WBETH** ≈ **17.2 % effective APY**.

Gas ~2.5 M (5× iter mint+borrow+deposit) ≈ $1.50.

## Risks
- **Liquidation cascade on ETH drawdown.** A 10 % drop in ETH leaves the
  loop at ≈ 99 % LTV and triggers a chain liquidation. Mitigation: cap
  effective leverage at 4×, use the per-block `getAccountLiquidity` read
  as a circuit breaker.
- **WBETH.deposit selector divergence.** The BSC WBETH `deposit` ABI may
  differ from mainnet. PoC catches the revert and continues with a
  1:1 internal accounting fallback so PnL still surfaces.
- **eMode tag misconfigured.** If governance has not yet tagged
  WBETH/WETH as correlated, the CF reverts to the cross-asset value
  (~75 %) and the loop converges much faster — fewer iterations, ~half
  the PnL. The test surface still runs.
- **WETH cash on LST pool too thin.** PoC clamps each iter's borrow to
  90 % of `getCash()`.

## Result
Status: **theoretical, offline**. Expected net **~$4.2k per $300k WBETH
per 30 days**. Strategy compiles and runs as a 1-iteration position
if the eMode tags or listings are absent.
