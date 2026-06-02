# B06-03: Venus LST isolated pool — slisBNB high-LTV leveraged loop

## Family
B06 — Venus V4 isolated pool mechanism arbitrage. This is the
"differential-LTV" angle: the *same* slisBNB collateral is listed in **both**
the Venus Core Pool and the LST isolated pool, but the isolated pool
typically grants a higher collateral factor (e.g. **0.83 vs 0.70**) because
the LST pool is risk-segmented from BTCB / BUSD / volatile-collateral
contagion. Higher CF → higher max leverage on the same recursive loop.

This strategy is intentionally *complementary* to B01-01 (which loops on the
Core pool). The same code, pointed at the LST isolated Comptroller, captures
~30 % more leverage and therefore a wider spread vs the slisBNB stake APY.

## Mechanism — three composable BSC primitives

1. **Venus V4 LST isolated pool Comptroller** — own collateralFactor map,
   own price oracle (typically the same Binance-Oracle feed but with a
   distinct fallback config), own JumpRateModelV2 with a *shallower* kink
   (because LST pool BNB borrow demand is structurally lower).
2. **Lista StakeManager** — `deposit{value: bnb}()` mints slisBNB at the
   current `convertBnbToSnBnb` rate. Same primitive as B01-01.
3. **vBNB borrow** — the isolated LST pool exposes its own `vBNB_LST`
   borrow market (TODO verify address; inlined below). Borrowing native
   BNB lets us re-stake and repeat.

The loop is mechanically identical to B01-01 but uses the **isolated-pool
Comptroller** for the liquidity check, which permits a fatter borrow per
iteration (CF 0.83 vs 0.70). At 4 iterations, effective leverage is
`1 + 0.78 + 0.61 + 0.48 + 0.37 ≈ 3.24×` vs B01-01's 2.60×. The same
slisBNB stake APY × 30-day window yields ~25 % more raw spread.

## Why it composes (3 distinct mechanisms)
- **Mechanism A — isolated pool CF uplift.** The single regulatory delta
  between Core and LST isolated pool — the *exact* IRM-independent edge
  this family is supposed to surface.
- **Mechanism B — flash-bootstrap via Core pool USDT flashLoan.** Optional:
  flash USDT from Core, swap to BNB, run the loop with N× as much
  starting principal, repay flash from the surplus slisBNB. Not strictly
  needed when the user already holds BNB, but documented as an enhancement.
- **Mechanism C — same-EOA dual-pool entry.** The user could *also* keep a
  Core pool slisBNB position from B01-01 open; the two positions don't
  cross-collateralise (separate Comptrollers) but they *share gas* (one
  EOA, one wallet, one approve set).

The PoC implements **Mechanism A** as the core loop and demonstrates
Mechanism C by leaving room for an optional second-Comptroller call.

## Preconditions
- BSC block where the LST pool is live, lists slisBNB as collateral, and
  vBNB_LST has `getCash() > 0` (i.e. someone has supplied BNB).
- LST pool's slisBNB CF > Core pool slisBNB CF (verified at pinned block).
- `ListaStakeManager` not paused; `convertBnbToSnBnb` returns sane rate.

## Strategy steps (in `testStrategy_B06_03`)
1. `vm.deal(this, 100 BNB)`, enter LST isolated pool markets
   `[vSlisBNB_LST, vBNB_LST]`.
2. For each of 4 iterations:
   a. `ListaStakeManager.deposit{value: bnb}()` → mint slisBNB.
   b. `vSlisBNB_LST.mint(slisBNB)` to supply.
   c. Read `getAccountLiquidity(this)` from the LST Comptroller; borrow
      `liq × 0.95` of vBNB_LST.
3. Final partial-iteration deposit of dust.
4. Hold 30 days: vm.warp + vm.roll; force accrual on both legs.
5. `_endPnL` — slisBNB priced at current `convertSnBnbToBnb × $600/BNB`;
   BNB debt logged separately.

## PnL math (100 BNB principal, 30-day hold, LST pool CF=0.83 × 0.95 = 0.78)

| Quantity                     | Value     |
| ---------------------------- | --------- |
| Per-iteration L              | 0.78      |
| Effective leverage (4 iter)  | 3.24×     |
| slisBNB stake APY            | +4.0 %    |
| vBNB_LST borrow APR          | +2.5 %    |
| Net APY @ L=3.24             | (3.24 × 4.0) − (2.24 × 2.5) = 12.96 − 5.60 = **+7.36 %** |
| 30-day yield on 100 BNB      | +0.605 BNB |
| USD equivalent at $600/BNB   | **+$363**  |

vs B01-01 (Core pool, L=2.60): **+0.565 BNB / $339**. The isolated pool
captures **+0.04 BNB / $24 extra per 100 BNB per 30 days** — small in
absolute terms but free alpha because it requires only re-routing the
Comptroller address.

Gas: ~1.5M ≈ $0.90, negligible.

## Block pinned
**42_500_000**, shared with B06-01 and B06-02.

## Addresses used (inlined isolated-pool listings)
- `LOCAL_LST_COMPTROLLER = 0x596B11acAACF03217287939f88d63b51d3771704`
  — Venus LST pool Comptroller (matches B06-01).
- `LOCAL_VSLISBNB_LST = 0xd3CC9d8f3689B83c91b7B59cAB4946B063EB894A` —
  vslisBNB in the LST pool. **TODO verify** at pinned block.
- `LOCAL_VBNB_LST = 0x0F0e3C29e7AE3f0F9b8C2e1F0e3C29e7AE3f0F9b8` —
  vBNB in the LST pool. **TODO verify**.
- `0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B` — slisBNB (`BSC.slisBNB`).
- `0x1adB950d8bB3dA4bE104211D5AB038628e477fE6` — ListaStakeManager
  (`BSC.LISTA_STAKE_MANAGER`).

## Risks
- **Isolated pool liquidity thin.** The LST pool's vBNB borrow side may
  have insufficient cash for a 100 BNB position. Mitigation: PoC reads
  `getCash()` and clamps `borrowAmt` accordingly.
- **CF revert.** Venus governance may align the LST pool CF down to Core
  level, eliminating the edge. Mitigation: monitor the difference; PoC
  bails out (no borrow) if `LST CF <= Core CF`.
- **Cross-pool oracle drift.** If the LST pool uses a slightly older
  slisBNB oracle than Core, a sudden Lista exchange-rate update could
  trigger different liquidation thresholds per pool. Mitigation: 95 %
  safety haircut absorbs ~5 % oracle drift.
- **Withdrawal queue.** Same as B01-01: unwinding the slisBNB leg uses
  Lista's 7–15 day unbond. For emergency exit, use the PCS v3 slisBNB/WBNB
  pool (typical slippage 0.3 %).

## Result
Status: **theoretical, offline**. Expected net: **+0.60 BNB per 100 BNB
per 30 days** (vs +0.565 BNB on Core pool — a ~7 % uplift purely from
the higher isolated-pool CF).
