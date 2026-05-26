# F11-05: Fluid sUSDe/USDC smart-collateral + Pendle PT-sUSDe (3-mech)

## Mechanism
Three orthogonal yield mechanisms stacked atomically:

1. **Ethena sUSDe** — ERC-4626 staked USDe earning the funding-rate spread
   between perp longs and short positions held by the protocol (~10-20 %
   variable APY, paid in USDe).
2. **Pendle PT-sUSDe (Mar 2025 maturity)** — locks the sUSDe yield by buying
   the discounted Principal Token. At maturity 1 PT redeems for 1 USDe; the
   purchase discount *is* the fixed-yield carry.
3. **Fluid sUSDe/USDC smart-collateral T4 vault** — the LP collateral position
   itself runs an embedded constant-product pool between sUSDe and USDC.
   Arbitrageurs that rebalance against Curve's sUSDe/USDC venues pay swap
   fees that accrue to the smart-collateral NFT holder.

The strategy supplies sUSDe + USDC into the Fluid T4 vault, simultaneously
holds the PT leg as duration hedge. The vault's smart-debt side (USDC) can
also be drawn against the position to scale exposure, but at higher LTV the
sUSDe/USDC pool-price drift becomes the dominant risk.

## Why it composes
- Ethena's sUSDe is **collateral-eligible** in the Fluid vault: it appears as
  side-A of the embedded LP. The vault treats wrapped sUSDe as a yield-bearing
  ERC-4626; oracle-priced via `convertToAssets`.
- Pendle's PT-sUSDe is a **non-yield-bearing duration claim**: by holding PT
  outside the Fluid vault we lock in the carry that would otherwise be exposed
  to Ethena funding-rate volatility. PT discount + sUSDe staking yield are
  not double-counted — they're *complementary* claims on the same future cash
  flow (one fixed, one variable).
- Fluid's smart collateral is **orthogonal to both**: the LP fee yield comes
  from arbitrage flow, not from the underlying. Three independent revenue
  streams, one position.

## Preconditions
- Mainnet at a block ≥ Fluid T4 sUSDe/USDC vault deployment (late 2024).
- Pendle PT-sUSDe market exists with positive carry (PT trading below 1
  USDe). At the pinned block (~Jan 2025) PT was at ~$0.94.
- USDC and USDe both liquid (always true on mainnet).

## Strategy steps
1. Allocate USDC principal: 70 % converted to USDe → sUSDe (Ethena), 30 %
   kept as USDC for the Fluid vault's USDC leg.
2. Buy PT-sUSDe (Mar 2025) at the prevailing discount.
3. Open Fluid sUSDe/USDC smart-collateral NFT with half the sUSDe + USDC at
   the pool ratio; keep PT-sUSDe outside the vault as duration claim.
4. Hold 30 days. Yields accrue:
   - Ethena sUSDe NAV grows (variable, observed via `convertToAssets`).
   - PT-sUSDe pulls to par (fixed, ~0.5 %/month at the pinned discount).
   - Fluid smart-col NFT accrues LP fees (variable, observed via vault state).
5. Optional: at PT maturity, redeem PT → sUSDe and consolidate.

## PnL math
Per 1M USDC principal, 30-day horizon, indicative rates:
- sUSDe yield: 0.70 × 0.12 × (30/365) = +0.0069 = **+0.69 %**
- PT pull-to-par (5 % discount, ~3 months to maturity): 0.20 × 0.05 × (30/90)
  = +0.0033 = **+0.33 %**
- Fluid LP fee: 0.30 × 0.04 × (30/365) = +0.0010 = **+0.10 %**

Sum: **+1.1 % over 30 days**, ~13 % APY gross. Risks scale primarily with
sUSDe NAV variance.

## Block pinned
**21_700_000** (Jan 2025) — Fluid T4 sUSDe/USDC vault live; PT-sUSDe Mar 2025
trading at ~$0.94; sUSDe APY ~12 %.

## Addresses used (verified)
- `0x025C1494b7d15aA931E011f6740E0b46b2136cb9` — Fluid sUSDe/USDC T4
  smart-collateral & smart-debt vault, verified at
  https://etherscan.io/address/0x025C1494b7d15aA931E011f6740E0b46b2136cb9
- `0xE00bd3Df25fb187d6ABBB620b3dfd19839947b81` — Pendle PT-sUSDe-27MAR2025,
  verified at https://etherscan.io/address/0xE00bd3Df25fb187d6ABBB620b3dfd19839947b81
- `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` — Ethena sUSDe (Mainnet.SUSDE)
- `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` — Ethena USDe
- `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` — USDC

## Risks
- **Ethena de-peg / funding-rate flip**: if perp funding turns persistently
  negative, sUSDe APY drops or the reserve fund is drawn. Cap risk because
  USDe is overcollateralised.
- **PT illiquidity at maturity**: if Pendle market for PT-sUSDe Mar 2025 is
  thin, exit before maturity may incur slippage.
- **Fluid oracle stall**: smart-col vault uses internal oracle for sUSDe
  pricing; oracle stall could grief the position.
- **Vault liquidation**: if leveraged via smart-debt, a 3 %+ sUSDe/USDC drift
  triggers absorption.

## Result
Status: theoretical (forge build not run). PoC opens the Fluid NFT, holds
PT + sUSDe through 30-day warp, and reports component balances. Expected
PnL: **+1.0-1.3 % over 30 days** at the pinned block.
