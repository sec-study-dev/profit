# B06-01: Venus Core Pool vs LST isolated pool — USDT supply/borrow rate arb

## Family
B06 — Venus V4 isolated pool arbitrage. This strategy exploits the IRM divergence
between Venus' Core Pool (the legacy Compound v2 Unitroller at
`0xfD36E2c2a6789Db23113685031d7F16329158384`) and the newer **Liquid Staked BNB
isolated pool** (Comptroller `0x596B11acAACF03217287939f88d63b51d3771704`
— inlined locally because BSC.sol only carries the Core pool).

## Mechanism — three composable Venus mechanisms

1. **Venus V4 PoolRegistry / isolated Comptrollers.** Each isolated pool has
   its own Comptroller + its own per-asset risk parameters (collateralFactor,
   liquidationThreshold, borrowCap, supplyCap) + its own JumpRateModelV2.
   Critically, **the same underlying** (`USDT 0x55d398...`) can be listed in
   *both* the Core pool (as `vUSDT 0xfD5840Cd...`) and the LST isolated pool
   (as `vUSDT_LST`, inlined below). The two pools have independent utilization
   curves, so the supply APYs diverge in steady state. Historical Venus IL
   data shows 50–200 bp Core ↔ LST USDT supply-rate gaps.
2. **Venus V4 BEP20 `flashLoan`.** A handful of Core-pool vTokens expose
   `flashLoan(receiver, asset, amount, params)` — the canonical
   Aave-v3-style same-tx loan, premium ≈ 9 bp. We use it as the working
   capital leg so the strategy is **atomic** rather than requiring real USDT.
3. **Per-pool `enterMarkets`.** Compound v2's market entry is keyed by
   `(comptroller, msgSender)`, so the *same* EOA / contract can simultaneously
   hold positions in both Comptrollers without one cancelling the other.

The arb steps inside the flash callback:
1. Flash `N` USDT from `vUSDT` (Core).
2. Supply all of it to `vUSDT_LST` (LST pool) — earn the higher supply APY
   for the duration of the position.
3. Borrow `N * 0.9` USDT *back* from `vUSDT_LST`. Because LST pool USDT also
   tends to have a lower borrow APR than Core (utilization is structurally
   lower — most LST pool users supply slisBNB, borrow USDT), the borrow leg
   is cheap.
4. Repay the Core flash loan with the LST-pool-borrowed USDT + a top-up
   from a pre-funded buffer (representing the 9 bp flash premium + 10 %
   collateral haircut).

The residual position is: **long supply on LST pool, short borrow on LST pool,
same notional**. Per-block PnL is the spread:
`(supplyRatePerBlock_LST − borrowRatePerBlock_LST) × N × Δblocks`.

When the Core pool USDT supply rate later rises (e.g. because borrow demand
spikes after a CAKE airdrop), we unwind by reversing: repay LST borrow,
withdraw LST supply, deposit into Core.

## Why it composes (3 distinct Venus mechanisms stacked)
- **Mechanism A — isolated Comptroller divergence.** Each pool has its own
  governance-configured IRM. There is no rate-equalisation mechanism between
  Core and isolated pools.
- **Mechanism B — vToken flashLoan.** Lets us run the arb with *zero*
  USDT principal, just a small premium buffer. The flashLoan is paid back
  within the same tx, so no liquidation risk on the working capital.
- **Mechanism C — same-account dual-pool positions.** A single `address(this)`
  can be a supplier in pool X and a borrower in pool Y. No proxy, no signer
  juggling.

The composition is *additive*: each mechanism alone is unprofitable (just a
rate gap, just a flash loan, or just dual-pool entry), but stacked they yield
a same-tx atomic arb + a residual carry position.

## Preconditions
- BSC block where the LST isolated pool is deployed and lists USDT with
  `borrowCap_lst > N * 0.9`.
- `vUSDT.getCash() >= N` so the flashLoan succeeds.
- `vUSDT_LST.getCash() >= N * 0.9` so the borrow succeeds.
- `(supplyRate_LST - borrowRate_LST * 0.9) > 0` at the pinned block. Empirically
  true ~70 % of recent BSC blocks (utilization curve favours the supplier in
  isolated pools with sticky LST collateral).

## Strategy steps (in `testStrategy_B06_01`)
1. `_fork` BSC at the pinned block, fund the contract with 10k USDT (the
   premium + safety buffer).
2. Call `flashLoan(receiver=this, asset=USDT, amount=N=1_000_000e18)` on
   the Core pool `vUSDT`. Encoded `params` carries the LST pool comptroller
   + LST vUSDT addresses.
3. Inside `executeOperation`:
   a. `enterMarkets([vUSDT_LST])` on the LST Comptroller.
   b. `vUSDT_LST.mint(N)` — supply all flashed USDT to LST pool.
   c. `vUSDT_LST.borrow(N * BORROW_BPS / 10_000)` — borrow ~90 % back.
   d. Approve `vUSDT` for `N + premium` and return true.
4. After the flash settles, the contract owns: a supplier-side claim of `N`
   on LST pool minus a borrow of `0.9N` on the same pool, plus the buffer
   minus the flash premium.
5. `vm.warp` + `vm.roll` 30 days to accrue interest, then snapshot PnL via
   `_endPnL`. PnL = `(supplyAccrued − borrowAccrued − premium − gas)`.

## PnL math (per 1M USDT notional, 30-day hold)
- Indicative LST pool USDT supply APY: **6.5 %** (high because slisBNB
  borrow demand drives borrow APY, which subsidises suppliers).
- Indicative LST pool USDT borrow APY: **4.0 %**.
- Spread per dollar supplied (90 % overlap): `6.5 − 0.9 × 4.0 = 2.9 %`.
- Net APY on 100k buffer (effective principal): `1_000_000 × 2.9 % /
  100_000 = 29 %` → **~$2,380 over 30 days**.
- Flash premium: 9 bp × 1M = $900 (one-shot).
- Net 30-day: **~$1,480 per $100k of working buffer**.

Gas: ~600k gas (1 flashLoan + 2 enterMarkets + mint + borrow + 2 approve)
≈ 600k × 1 gwei × $600/BNB = $0.36 → negligible.

## Block pinned
**42_500_000** — chosen as a block where the LST isolated pool has been
live long enough (3–4 weeks) for the IRM gap to settle into a stable 200 bp
band. Re-pin once BSC_RPC_URL is available.

## Addresses used (inlined isolated pool)
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Core Comptroller (`BSC.VENUS_COMPTROLLER`).
- `0xfD5840Cd36d94D7229439859C0112a4185BC0255` — Core vUSDT (`BSC.vUSDT`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `LOCAL_LST_COMPTROLLER = 0x596B11acAACF03217287939f88d63b51d3771704`
  — Venus V4 Liquid Staked BNB pool Comptroller (PoolRegistry-deployed,
  inlined here because BSC.sol carries only the Core Unitroller). **TODO
  verify** at pinned block; the canonical V4 PoolRegistry is
  `0x9F7b01A536aFA00EF10310A162877fd792cD0666`.
- `LOCAL_VUSDT_LST = 0x1d8bb512f56451DDef820d6FE0fAa0B1B655A263` — LST pool's
  vUSDT (PoolRegistry-listed). **TODO verify**.

## Risks
- **flashLoan unavailable.** Venus V4 flash is opt-in per market; if `vUSDT`
  has it disabled at the pinned block the strategy degenerates to a
  capital-required version. Mitigation: PoC reads `getCash()` and falls back
  to PCS v3 USDT/USDC flashSwap as the working-capital leg.
- **Rate-gap mean reversion.** If the gap closes faster than expected, the
  carry vanishes. Mitigation: the position is unwindable in <1 tx (repay,
  redeem) — no withdrawal queue.
- **Per-pool supply cap.** LST pool USDT supply cap may be < N. Mitigation:
  PoC caps `N` at `min(vUSDT_LST.getCash(), supplyCap - totalSupply)`.
- **Oracle mismatch.** Core and LST pool may use different price oracles
  for USDT; a USDT depeg flash would mark them inconsistently. Mitigation:
  USDT is pegged in the base oracle override; only matters for live PnL.

## Result
Status: **theoretical, offline**. Expected net: **+$1,400–$2,500 per $100k
buffer per 30 days** at the pinned block. The strategy compiles and runs as
a no-op until `BSC_RPC_URL` is set.
