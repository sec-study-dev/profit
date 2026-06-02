# B15-03 — PCS v3 flash + Pendle PT-sUSDe + Venus atomic levered carry

## Family

B15 · 三协议机制堆叠. Atomic single-tx variant of the B15-01 positional
stack: flash-borrow USDC, lock the PT yield, supply to Venus, borrow the
USDC back to repay the flash — leaving a fully-flashed leveraged PT
position whose only equity is the entry discount.

## Thesis

PT-sUSDe-BSC trades at ~10–14 % implied APR. If we can take Venus
collateral against the PT (or its underlying SY/USDe), then a PCS v3 flash
loan lets us open the position **with zero seed capital** — only
gas + flash-fee + entry-slip:

1. **PCS v3 flash** the USDC notional (BSC's cheapest 1 bp flash source).
2. **Pendle BSC Router V4** — `swapExactTokenForPt(market=PT-sUSDe-26JUN2025,
   tokenIn=USDC)`. PT is now in the contract.
3. **Venus Core** — supply the PT (or fall back to the underlying USDe/
   USDC) as collateral, borrow back the USDC amount needed to repay the
   flash (≈ 90 % LTV → 90 % of the borrow returns to the pool).
4. Repay the PCS v3 flash inside `pancakeV3FlashCallback` — leaves a
   levered PT position with USDC debt outstanding on Venus.

The position earns `PT_fixed_yield × notional − Venus_USDC_borrow_rate
× notional` per unit time. PT discount is *fixed* at entry, so any rise
in Venus borrow rate over the maturity is the only floating risk.

## Why it composes — the 3 mechanisms

1. **PCS v3 pool flash (`flash()`)** — the only fee-cheap flash source on
   BSC for USDC notional (1 bp via the USDC/USDT 100-bp pool). Without
   it, the strategy requires seed capital equal to the PT entry.
2. **Pendle Router V4 `swapExactTokenForPt`** — only protocol on BSC that
   lets a flash-borrowed dollar lock into a *non-marketable* fixed yield.
   Without Pendle, the alternative is a vUSDT supply (variable rate),
   which leaves the carry exposed to the borrow rate flip.
3. **Venus `vToken.borrow`** — only BSC money market with enough USDC
   cash to absorb the borrow-back leg without significant rate impact.
   It closes the flash loop and provides the static funding rate.

**No 2-mechanism subset achieves "zero-seed levered fixed carry":**
- (PCS flash + Pendle) — buys PT but cannot repay the flash; flash
  reverts.
- (PCS flash + Venus) — opens a Venus levered position but no fixed-yield
  leg; this is the B07/B06 territory.
- (Pendle + Venus) — opens a levered PT position but requires seed
  capital matching the PT entry amount. The PCS v3 flash converts seed
  capital → flash + 1 bp fee.

The triple-stack is the only construction that opens a **levered, fixed-
yield, zero-seed** PT position atomically.

## Preconditions

- PCS v3 USDC/USDT 0.01 % pool has cash > flash notional.
- Pendle BSC router live and PT-sUSDe-26JUN2025 market liquid.
- Venus Core lists PT-sUSDe as collateral (or USDe / USDC as fallback,
  with the PT held off-collateral as pure yield exposure).

## Strategy steps (PoC)

1. Initiate flash: `IPancakeV3Pool(USDC/USDT 100bp).flash(this, USDC_AMT,
   0, calldata)`.
2. Inside `pancakeV3FlashCallback`:
   1. Approve Pendle router; `swapExactTokenForPt(..., tokenIn=USDC,
      market=PT_SUSDE_MARKET, ...)` → receive `ptOut`.
   2. Approve and supply PT (or fallback USDe) to Venus, enter market.
   3. `IVToken.borrow(USDC, repayAmount + flashFee)` — pulls USDC out of
      Venus matching the flash repayment.
   4. Transfer the borrowed USDC back to the PCS v3 pool.
3. After return, the contract holds `ptOut` (collateralised on Venus)
   and owes USDC to Venus. Equity = `entryDiscount × ptOut` — the
   present value of the fixed carry to maturity.

For the offline PoC we skip the actual callback and model each leg
inline so the bookkeeping is auditable.

## PnL math

`PT_NOTIONAL = 500_000 USDC`. Entry discount @ 12 % APR for 180 days =
`1 - 1/(1.12^0.5) ≈ 5.7 %` → equity ≈ `+28 500 USDC` of PV.

Per-period carry (180 days held to maturity):
- PT yield: 500 000 × 0.12 × 0.5 = **+30 000 USDC**
- Venus USDC borrow on ~450 000 (after 90 % LTV): 450 000 × 0.07 × 0.5 = **−15 750 USDC**
- PCS v3 flash fee: 500 000 × 0.0001 = **−50 USDC** (one-shot)
- Gas + entry slip: **−$10**

**Net: ≈ +14 200 USDC over 180 d on ~$28 k of equity → ~50 % APR.**

## Block pinned

`FORK_BLOCK = 42_700_000`. Re-pin once BSC Pendle market is confirmed.

## Addresses used

- `BSC.PCS_V3_ROUTER`, `BSC.PCS_V3_FACTORY`, USDC/USDT 100-bp pool (resolved
  via factory).
- `BSC.PENDLE_ROUTER_V4` (// TODO verify).
- `BSC.VENUS_COMPTROLLER`, `BSC.vUSDC`, `BSC.vUSDT`, `BSC.USDC`, `BSC.USDT`.
- `LOCAL_PT_SUSDE_MARKET` — inline placeholder.

## Risks

- **PT not Venus-listed**: Venus Core may not list PT-sUSDe directly. The
  PoC falls back to supplying USDe/USDC to Venus (giving up the PT-Venus
  collateral leg) and holding PT off-collateral. PnL drops by half.
- **Venus borrow cap**: vUSDC borrow may be capped per-account at the
  fork block. Reduce notional if reverted.
- **PT discount widen pre-maturity**: only matters if forced to unwind
  before expiry. The flash repayment is atomic so a reversion is
  no-loss.
- **Flash-fee skew**: PCS v3 USDC/USDT 100-bp pool typically charges
  1 bp; the 500-bp pool charges 5 bp. PoC reads `fee()`.

## Result

Status: **offline-draft**. Expected PnL: **+14 000 USDC over 180 d on
~$28 k equity (~50 % APR)** if PT is Venus-collateral-eligible, ~25 %
APR otherwise.

## TODO

- Implement the real `pancakeV3FlashCallback` once a BSC fork is wired;
  the offline PoC inlines the legs.
- Confirm Venus PT-sUSDe listing or fall back to canonical USDe-collateral
  path.
- Resolve the USDC/USDT 100-bp pool address via PCS V3 Factory at
  runtime.
