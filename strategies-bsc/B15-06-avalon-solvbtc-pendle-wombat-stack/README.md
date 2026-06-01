# B15-06 — Avalon solvBTC · Pendle PT-solvBTC · Wombat BTC stable basis

## Family

B15 · 三协议机制堆叠. BSC's BTC-yield triple stack: collateralise a
BTC-LSD on Avalon, lock the LSD's accrual on Pendle, and recycle the
borrowed BTC notional into Wombat's BTC stable pool — a three-mechanism
construction analogous to F18's "wstETH + Pendle + Morpho" but
denominated in BTC.

## Thesis

`solvBTC` and `solvBTC.BBN` are the major BTC-LSDs on BSC. Their underlying
yield (Babylon restake on BBN, basis on solvBTC) is opaque and slow-
moving. Pendle BSC tokenises the solvBTC yield curve into PT/YT; Avalon
(Aave V3 fork) lends against solvBTC; Wombat runs a `USDX`-style BTC-side
stable pool.

The triple stack:

1. **Avalon supply + borrow** — `IAvalonLendingPool.supply(solvBTC, X)`,
   then `borrow(BTCB)` at ~60 % LTV. The solvBTC collateral keeps
   earning its underlying restake/basis yield.
2. **Pendle PT-solvBTC** — convert the freshly-borrowed `BTCB` to
   `PT-solvBTC-26JUN2025` via `swapExactTokenForPt`. The PT yield is
   typically *higher* than the underlying solvBTC's floating accrual
   (Pendle prices in a risk premium for fixed-yield).
3. **Wombat BTC stable pool** — the PT-solvBTC's eventual maturity
   payoff is in solvBTC; we deposit a fraction of the borrowed BTCB
   into Wombat's BTCB/solvBTC stable pool to earn LP fees + WOM
   emissions (Wombat's BTC pool has been heavily incentivised by Lista
   bribe distributions).

End state: equity-equivalent BTC exposure ~2.5× notional, with three
independent yield streams (Avalon supply yield, Pendle PT fixed yield,
Wombat LP fees + WOM emissions).

## Why it composes — the 3 mechanisms

1. **Avalon Lending Pool (Aave V3 fork)** — only BSC money market with
   *deep BTC-LSD collateral support*. Venus's BTC market is BTCB-only;
   Avalon lists solvBTC and solvBTC.BBN as collateral with sane LTVs.
2. **Pendle BSC Router V4 `swapExactTokenForPt`** — only protocol on BSC
   that tokenises the solvBTC yield curve. Without Pendle, the strategy
   leaves the borrowed BTCB sitting at the variable rate.
3. **Wombat BTC stable pool LP** — Wombat's BTCB/solvBTC pair is the
   *only* dynamic-asset-weight BTC stable pool on BSC. The asymmetric
   curve makes single-sided BTCB deposit cheap and lets the LP capture
   solvBTC↔BTCB rebalancing fees.

**No 2-mechanism subset works:**
- (Avalon + Pendle) alone: a levered fixed-yield carry (B12 territory),
  no LP fees + WOM emissions.
- (Avalon + Wombat) alone: a BTC-loop with LP yield, no PT amplification
  — gives up Pendle's fixed-yield premium.
- (Pendle + Wombat) alone: a PT + LP carry but no balance-sheet
  leverage — requires seed BTCB matching the position size.

The triple uniquely (a) levers the position via Avalon, (b) locks PT
yield on the borrow leg, **and** (c) skims LP fees from the
restake-token's stable pool.

## Preconditions

- Avalon lists solvBTC as collateral with non-trivial supply cap.
- Pendle BSC PT-solvBTC market live and has > 100 BTC notional liquidity.
- Wombat BTC stable pool (solvBTC/BTCB) live.

## Strategy steps (PoC)

1. Fund 5 solvBTC equity (~$325 k at $65 k/BTC).
2. **Leg A**: `IAvalonLendingPool.supply(solvBTC, 5e18, this, 0)`,
   enter market, `borrow(BTCB, 3e18, RATE_VARIABLE, 0, this)` (60 % LTV).
3. **Leg B**: Approve BTCB to Pendle, swap to `PT-solvBTC-26JUN2025`.
   Allocate 70 % of borrowed BTCB to PT (2.1 BTC).
4. **Leg C**: Allocate remaining 30 % of borrowed BTCB to Wombat:
   `IWombatPool.deposit(BTCB, 0.9 BTC, ..., shouldStake=false)`.
5. Hold; periodic interest claim from Avalon + Wombat LP fee accrual +
   PT decay-to-maturity.
6. PnL closed at maturity (PT 1:1 redeem to solvBTC) or
   marked-to-market at `HOLD_DAYS`.

## PnL math

5 solvBTC ≈ $325 000, 180 days held (PT maturity):
- solvBTC native restake APR on 5 supplied: 5 × 65 000 × 0.045 × 0.5 =
  **+$3 656**
- PT yield on 2.1 BTC notional @ 8 %: 2.1 × 65 000 × 0.08 × 0.5 = **+$5 460**
- Wombat fees + WOM emissions on 0.9 BTC @ 10 %: 0.9 × 65 000 × 0.10 ×
  0.5 = **+$2 925**
- Avalon BTCB borrow on 3 BTC @ 4.5 %: 3 × 65 000 × 0.045 × 0.5 = **−$4 388**
- Avalon supply boost on solvBTC ~+0.5 %: 5 × 65 000 × 0.005 × 0.5 = **+$406**

**Net: ≈ +$8 059 over 180 d on ≈ $325 k seed = ~5 % half-year ≈ 10 % APR.**

(Conservative — Wombat's WOM emissions can spike on bribe-heavy weeks.)

## Block pinned

`FORK_BLOCK = 42_650_000` (early Q1 2025; Avalon BSC + solvBTC pools
established).

## Addresses used

- `BSC.solvBTC`, `BSC.solvBTC_BBN`, `BSC.BTCB`.
- `BSC.AVALON_LENDING_POOL` (// TODO verify).
- `BSC.PENDLE_ROUTER_V4`, `LOCAL_PT_SOLVBTC_MARKET` — inline placeholder.
- `BSC.WOMBAT_MAIN_POOL`, `BSC.WOMBAT_ROUTER`.

## Risks

- **solvBTC depeg from BTC**: Avalon liquidation triggers if solvBTC
  loses peg by > LTV margin. 60 % LTV target buffers ~25 % below the
  ~85 % liquidation threshold.
- **Avalon supply cap**: cap on solvBTC collateral may revert; PoC
  try/catches.
- **Pendle PT-solvBTC discount widen**: only matters on early unwind;
  held to maturity captures the entry-locked yield.
- **Wombat BTC pool over-skew**: if BTCB-side gets over-supplied, the
  single-sided withdraw incurs the coverage-ratio penalty.

## Result

Status: **offline-draft**. Expected PnL: **+$8 000 / 180 d / $325 k
seed (~10 % APR)** with three independent BTC-side yield streams.

## TODO

- Confirm Avalon lending pool address + solvBTC LTV configuration.
- Verify Pendle BSC PT-solvBTC market.
- Resolve the canonical Wombat BTC-stable pool (may be a separate pool
  from `WOMBAT_MAIN_POOL`).
