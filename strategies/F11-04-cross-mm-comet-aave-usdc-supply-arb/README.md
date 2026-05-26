# F11-04: Cross-MM Comet ↔ Aave USDC supply-rate arbitrage

## Mechanism
Compound v3 USDC Comet and Aave v3 each maintain independent USDC markets
with independent IRMs. Comet's USDC IRM is governed by a tri-piecewise curve
with a kink at ~85 % utilisation; Aave v3's USDC reserve uses a similar
two-slope model but with different parameters and a different optimal-use
point. The two curves *frequently diverge* over short horizons because the
markets respond asymmetrically to deposit / borrow flows.

When Aave's USDC **supply** APY rises above Comet's USDC **borrow** APR, an
atomic arb exists: flashloan USDC, supply it to Aave (mints aUSDC), borrow
USDC from Comet against a WETH collateral position already opened in Comet,
repay the flashloan, and pocket the rate differential on the *outstanding*
position over the holding horizon. This is *not* an instantaneous arb — it
captures a yield-curve dislocation that persists until the markets equilibrate.

This PoC executes the **opening** of such a position deterministically on a
pinned block, then warps 30 days to surface the realised spread.

## Why it composes
Two distinct money markets with shared underlying = a yield-curve term-
structure trade. Aave's larger USDC reserve (~$1.5B mid-2024) takes longer
to digest flow than Comet's smaller reserve (~$500M), so a supply shock to
one tends to compress its rate faster, opening a temporary spread.

The "composability" is at the *strategy* level: the same USDC is doing
double duty — as Aave deposit (earning supply yield) and as Comet borrow
(paying borrow APR). The net position is **zero principal at risk in USDC**
(modulo Aave/Comet smart-contract risk), but extracts the
`supply_aave - borrow_comet` spread continuously.

The WETH collateral in Comet is the only directional leg; the user can hedge
it with a delta-equivalent short on Coinbase futures or simply size it small
relative to the carry trade.

## Preconditions
- Mainnet, block where both markets are live and the rate inequality holds.
- WETH collateral pre-supplied to Comet (or supplied at the start of the
  arb sequence).
- Aave v3 USDC reserve not at supply cap (~$2.5B historically).
- Capital: directly proportional to the desired carry — gas-bound below
  ~$100k notional.

## Strategy steps
1. Supply WETH to Comet USDC (collateral leg). Skip if already supplied.
2. Borrow USDC from Comet (`Comet.withdraw(USDC, amount)`) against the WETH.
3. Supply that USDC to Aave v3 (`pool.supply(USDC, amount, self, 0)`).
4. Set USDC as Aave collateral (auto-on by default; explicitly call
   `setUserUseReserveAsCollateral(USDC, true)`).
5. Hold 30 days.
6. Unwind: `pool.withdraw(USDC, all, self)` → `Comet.supply(USDC, all)` to
   repay → `Comet.withdraw(WETH, all)` to recover collateral.

The PoC stops at step 4 plus the 30-day warp, then reports the on-chain
balances of aUSDC and Comet debt to surface the realised carry.

## PnL math
Let:
- `r_a` = Aave USDC supply APY ≈ 0.075 (varies; mid-2024 typical)
- `r_c` = Comet USDC borrow APR ≈ 0.060

Net spread on the carried notional `N`:
```
spread = r_a - r_c ≈ 0.015 (150 bps)
30-day net = N * spread * (30/365) = N * 0.00123
```
On `N = $1m`: ~$1230 gross per month. WETH collateral leg is delta-1 to ETH
and earns no Comet yield (Comet does not pay yield on non-base collateral).

For the strategy to be profitable on a 30-day horizon at $1m N:
- Required spread > breakeven covering ~$50 of gas (open + unwind ~1.2M gas).
- Spread persistence: at least 7 days at >100 bps, else the PoC carry is dust.

## Block pinned
**20_700_000** (Sep 2024) — a period where USDC was migrating between
markets after Aave's GHO yield-boost shake-out, surfacing a typical
80-170 bps spread between Comet and Aave on USDC.

## Addresses used (verified)
- `0xc3d688B66703497DAA19211EEdff47f25384cdc3` — Comet USDC, verified at
  https://etherscan.io/address/0xc3d688B66703497DAA19211EEdff47f25384cdc3
- `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2` — Aave v3 mainnet Pool, verified
  at https://etherscan.io/address/0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2
- `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` — USDC
- `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` — WETH9

## Risks
- **Spread compression**: the same arb path is open to many keepers; the
  spread typically narrows within hours of opening.
- **Rate flip**: if Comet borrow rate climbs above Aave supply rate (e.g.
  because of a large USDC borrow on Comet), carry inverts and the position
  bleeds.
- **Liquidation**: WETH collateral on Comet at 82.5 % LTV; a sharp ETH crash
  liquidates. The USDC borrow notional is matched by the Aave USDC supply,
  so the *only* unhedged leg is ETH directional.
- **Aave supply cap**: if the reserve hits its cap, `supply` reverts and the
  arb cannot be opened.
- **Smart-contract risk**: Comet + Aave + their respective oracles.

## Result
Status: theoretical (forge build not run; both market addresses verified).
Expected PnL on 100 ETH WETH collateral + $200k USDC borrowed:
`200_000 * 0.0015 * 30/365 ≈ $25` over 30 days, gross of gas. The PoC reports
the realised aUSDC + Comet-debt deltas. At larger N the carry scales linearly
until either market's IRM kinks.
