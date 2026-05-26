# F17-04: OUSD rebase passthrough via Aave supply (with wOUSD wrapper variant)

## Mechanism

This strategy tests whether **OUSD's rebase yield is captured when supplied
to Aave V3** — a non-obvious question because Aave's aToken model already
rebases (its own interest), and stacking a rebasing-collateral with a
rebasing aToken depends on Aave's listing configuration.

Two scenarios are explored, both pinned at the same fork block:

**Variant A — direct OUSD on Aave** (test-only; Aave does NOT list OUSD as
a reserve at FORK_BLOCK, so this is the diagnostic branch).

**Variant B — wrapped OUSD (wOUSD, the non-rebasing ERC4626 wrapper)** —
Origin provides `wOUSD` (`0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62`), an
ERC-4626 vault that converts the rebasing OUSD into a price-appreciating
share. Aave V3 *can* list wOUSD as a reserve (some forks/DAOs have done
this); if at the pinned block the wOUSD reserve exists, the PoC supplies
wOUSD, borrows USDC, swaps USDC -> OUSD via Curve, wraps to wOUSD, and
loops.

Mechanics:

1. **OUSD** (`0x2A8e1E676Ec238d8A992307B495b45B3fEAa5e86`) — Origin USD;
   rebasing yield aggregator over Aave/Compound/Convex strategies. APY
   reported by Origin (Aug 2024): ~6.5%.
2. **wOUSD** (`0xD2af830E8CBdFed6CC11Bab697bB25496ed6FA62`) — Origin's
   ERC-4626 wrapper. `convertToAssets(shares)` grows with each rebase; share
   count stays constant.
3. **Curve OUSD/3CRV pool** (`0x87650D7bbfC3A9F10587d7778206671719d9910D`)
   — primary liquidity venue for OUSD vs USDC/USDT/DAI.
4. **Aave V3 Pool** (`0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`) — supply
   wOUSD as collateral (if listed); borrow USDC.

```
seed USDC --swap-> OUSD --wrap-> wOUSD --supply-> Aave
                                                    |
                                                    v
                                                   borrow USDC
                                                    |
                                                    v
                                                  back to OUSD via Curve
                                                    (loop)
```

The looped position earns the **wOUSD share appreciation** (≈ OUSD APY less
wrapper fee) on the levered amount, minus the Aave USDC variable borrow
rate on the borrowed leg.

## Why it composes

- **Rebase-to-non-rebase wrapper** is the universal pattern for making a
  rebasing yield-bearing stable compatible with money markets that
  assume share-based accounting. The same pattern applies to stETH ->
  wstETH, USDM -> wUSDM, etc. Capturing this via Aave is a clean
  generalization.
- **Yield-stack stacking.** wOUSD's underlying yield is itself sourced from
  Aave/Compound/Convex; supplying wOUSD to Aave creates a recursive yield
  pile-up where the user receives wOUSD's *aggregated* basket yield
  amplified by Aave-listed leverage.
- **Diagnostic value** even if Aave does NOT list wOUSD: the PoC reads
  Aave's reserves list, detects listed/unlisted status, and reports
  cleanly. This is a useful negative result for the family (Origin's USD/
  ETH products lack first-class lending market integration on mainnet vs
  L2s).

## Preconditions

- A block where:
  - OUSD's Curve pool is liquid.
  - wOUSD contract is deployed.
  - (Variant B) Aave V3 has a wOUSD reserve. If not, PoC documents the
    finding and exits as no-op.

## Strategy steps

1. Pin fork to **block `20_500_000`** (Aug 2 2024).
2. Seed `address(this)` with `50_000` USDC.
3. Swap USDC -> OUSD on Curve OUSD/3CRV pool. (OUSD is a 4-coin pool:
   coin0=OUSD, coin1-3=DAI/USDC/USDT.)
4. Wrap OUSD -> wOUSD via `wOUSD.deposit(amount, this)`.
5. **Inspect Aave**: read `getReserveData(wOUSD)`. If `aTokenAddress ==
   address(0)`, wOUSD is unlisted; report diagnostic and exit.
6. If listed: `aave.supply(wOUSD, ..., this, 0)`, then `aave.borrow(USDC,
   ..., 2, 0, this)` at ≤80% of `availableBorrowsBase`.
7. Loop: borrowed USDC -> OUSD via Curve, wrap to wOUSD, supply.
8. Warp 30 days; measure share-price appreciation; unwind.
9. PnL = end-USDC - seed-USDC.

## PnL math

Define:
- `r_w = wOUSD APY` ≈ OUSD APY (Origin charges no extra wrapper fee) ≈ 6.5%
- `r_b = Aave USDC variable borrow APY` ≈ 5% (at FORK_BLOCK, Aug 2024)
- `L = effective leverage` from looping = 1 / (1 - LTV * safe_frac). At
  LTV=0.65 (typical for a yield-bearing stable on Aave) and safe_frac=0.8,
  `L ≈ 1 / (1 - 0.52) = 2.08x`.

Net APY on equity:
```
APY = L * r_w - (L - 1) * r_b
    = 2.08 * 0.065 - 1.08 * 0.05
    = 0.1352 - 0.054
    = 0.0812 = 8.12%
```

vs unlevered `r_w = 6.5%` → uplift of ~1.6%/yr on equity. Over 30 days on
$50k seed: ≈ $69 incremental over unlevered. Gross 30-day position yield ≈
$334.

Gas: 2 Curve swaps + 2 wrap/unwrap + 2 Aave supply/borrow + loop iterations
≈ 1.2M gas → $36 at 30 gwei.

## Block pinned

`20_500_000` (Aug 2 2024). OUSD Curve pool ~$5M TVL; Origin APY visible at
6.5%. wOUSD wrapper live and active.

## Risks

- **Aave does NOT list wOUSD as collateral.** Very likely as of mid-2024
  on mainnet (wOUSD only listed on some L2 Aave deployments). PoC handles
  this gracefully as a no-op with diagnostic logging — this is the
  expected output, not a failure mode.
- **OUSD basket yield collapse.** OUSD's APY depends on its underlying
  strategy allocation; if AAVE/Compound USDC rates drop to <1%, OUSD APY
  collapses with them and the loop loses to the borrow rate.
- **Curve OUSD pool depeg.** OUSD has historically traded at small
  premiums and discounts. Entry/exit slippage scales with pool TVL and
  trade size.
- **Origin governance pause.** Origin can pause OUSD minting via vault
  if a strategy contract is compromised; existing positions remain
  redeemable.
- **Rebase double-counting risk.** If Aave somehow listed OUSD *directly*
  (not wOUSD), supplying OUSD would yield aToken units that ALSO
  rebase, but Aave's rebasing aToken is interest-paid in different
  units — the actual yield captured by the aToken holder when supplying
  a rebasing-balance token is **uncertain** (Aave's internal scaledBalance
  tracking assumes the underlying does not rebase). This is the primary
  reason wOUSD exists. The PoC documents this concern and does NOT attempt
  direct OUSD-on-Aave.

## Result
Status: theoretical
Expected PnL: ~8.12% APY on equity if wOUSD listed (~$69 uplift over $334 gross per $50k seed over 30 days at OUSD APY=6.5%, Aave USDC borrow=5%, L=2.08x); $0 if unlisted (dominant mainnet state)

A diagnostic-and-loop PoC that (a) measures the actual capability of Aave
to integrate Origin OUSD via wOUSD at the pinned block, (b) executes a
2x-leverage loop if the integration exists, and (c) records the
no-integration-available state as the dominant production reality on
mainnet. This is the canonical example of why rebasing tokens require
wrappers to enter money markets.
