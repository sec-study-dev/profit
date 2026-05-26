# F01-06: wstETH on Compound v3 WETH Comet — leveraged loop

## Mechanism
Compound v3 ("Comet") on Ethereum mainnet operates as a set of single-borrow-
asset markets. The **WETH Comet** (`0xA17581A9E3356d9A858b789D68B4d866e593aE94`)
accepts a basket of correlated LST collaterals — wstETH, cbETH, rETH, wETH-as-
gas-only-substitute — and lets borrowers draw WETH against them. This is the
*native* WETH-borrow venue on Compound v3 (separate from the well-known USDC
Comet used by F11-01) and uses a per-collateral *borrow collateral factor* of
**90%** for wstETH at the pinned block (verified via `getAssetInfoByAddress`
on the Comet at fork).

Comet's interest-rate model is structurally distinct from Aave/Morpho:
- Single base asset (WETH) with no per-asset listings — collateral assets do
  not earn supply yield (this is the key trade-off vs Aave).
- Rate model is **kinked piecewise-linear** like Compound v2 but with three
  segments and per-second compounding via `accrueAccount`.
- No e-mode; the borrow-collateral-factor is a per-asset constant set by
  governance.
- Native flashloan is absent (must use external flash).

Borrowing on Comet does not generate aToken/cToken balances — the borrow is
expressed as a **negative principal** on `userBasic`, redeemed by repaying
WETH. The strategy supplies wstETH, draws WETH against it, converts WETH back
to wstETH via Curve stETH/ETH + Lido wrap, and re-supplies. The net carry is
`K * stETH_yield - (K-1) * Comet_WETH_borrow_apy`.

## Why it composes
The composition is two-mechanism (LST + new lending venue). It is *not*
3-mechanism but it deepens F01 coverage along a previously-unaddressed axis:
the **Compound v3 IRM curve** is different from Aave's. At low utilisation
(< 80%) Comet's WETH borrow APR is consistently 30-80 bp **below** Aave's
e-mode WETH rate because Comet's three-segment kink keeps the rate flatter
in the safe zone. At high utilisation (> 90%) Comet's rate ramps faster than
Aave's — a regime to avoid.

The composition adds value by giving the LST looper a **rate-venue choice**:
F01-01 (Aave eMode), F01-02 (Morpho 94.5%), and F01-06 (Comet WETH) span the
three production WETH-lending IRMs on mainnet. A sophisticated operator
rotates among them block-to-block when the *rate spread minus rotation gas*
becomes profitable. The Comet leg is unique in that it offers no supply-side
yield on collateral, removing the wstETH supply-APR cushion (0.05% on Aave)
in exchange for a cleaner rate curve.

## Preconditions
- Mainnet block where wstETH is listed as collateral on the Comet WETH market
  (since mid-2024) with non-zero borrow cap headroom.
- Block snapshot: Comet WETH variable APR < wstETH stake APR (typical when
  utilisation < 85%).
- Curve stETH/ETH pool depth ≥ K * principal ETH at < 10 bps depeg.

## Strategy steps
1. WETH → ETH → stETH (Lido submit) → wstETH (wrap).
2. Approve wstETH to Comet, `supply(wstETH, amount)` — credits wstETH as
   collateral (does not change user principal).
3. Loop N times:
   a. Compute borrowable WETH from current wstETH collateral × 0.90 × LTV
      target × ETH price (Comet uses internal 1e8 price scale).
   b. `withdraw(WETH, borrowAmt)` — when net principal is negative this
      becomes a *borrow* under Comet semantics.
   c. WETH → ETH → stETH → wstETH.
   d. `supply(wstETH, ...)` to re-collateralise.
4. After N loops: `K*P` wstETH collateral, `(K-1)*P` WETH debt.
5. Park for 30 days; call `accrueAccount` to crystallise interest.

## PnL math
Let:
- `s` = wstETH stake APR ≈ 0.030
- `b` = Comet WETH variable borrow APR ≈ 0.018 (at 75% utilisation, lower
  than Aave's 0.022 at the same utilisation due to flatter kink)
- `L` = 0.85 (Comet wstETH borrow-collateral-factor is 0.90; 5 pt buffer)
- `K = 1/(1-L) = 6.67`

```
net_apy = K * s - (K - 1) * b
        = 6.67 * 0.030 - 5.67 * 0.018
        = 0.200 - 0.102
        = 0.098 (~9.8% APY on principal)
```

Per 100 ETH over 30 days: `100 * 0.098 * 30/365 ≈ 0.80 ETH` gross
(~$2.0k @ $2.5k/ETH).

Comet supplies no collateral-yield, so the carry is purely the stake-spread
minus borrow. Lower than F01-01 (K=10) because lower leverage, but
**different rate exposure** — useful at blocks where Aave's WETH borrow APR
spikes due to Aave-specific utilisation events.

## Block pinned
**20_800_000** (Sep-Oct 2024) — Comet WETH market mature; wstETH borrow-CF
verified ≥ 0.88 via `getAssetInfoByAddress`; Comet WETH borrow APR observed
in 1.7-2.0% range; ample borrow capacity (> 50k WETH free).

## Risks
- **No collateral-side yield**: unlike Aave, Comet collateral assets do not
  accrue supply APR; strategy loses ~5 bp/yr of carry vs F01-01.
- **wstETH/ETH depeg**: Comet uses Chainlink wstETH/ETH composition; a sudden
  AMM-side discount that the oracle hasn't ingested yet creates a soft
  liquidation window.
- **Comet borrow-cap binding**: per-asset supply cap also enforced; large
  positions must check `getAssetInfo`.
- **Single-base-asset risk**: a Comet WETH liquidity crunch (mass borrow with
  insufficient supply) cannot be relieved by cross-asset rotation as on Aave.
- **No e-mode multiplier**: the structure is strictly less capital-efficient
  than Aave eMode at high LTV; the strategy is rate-arbitrage not LTV-max.

## Result
Status: theoretical (Comet WETH market + wstETH listing verified via
`getAssetInfoByAddress` ABI signature; not run on-fork).
Expected PnL: **+0.7% to +0.9% over 30 days** on 100 ETH principal at K≈6.7;
~$1.7-2.3k. Lower than F01-01/02 (less leverage) but rate-venue diversified.
