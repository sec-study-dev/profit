# F05-07: crvUSD (WETH-LLAMMA) → sUSDe Morpho recursive carry

## Mechanism

True three-mechanism (in fact four-protocol) carry chain that turns WETH
into levered sUSDe exposure:

1. **Curve crvUSD WETH-market LLAMMA borrow** (verified controller
   `0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635`, LLAMMA
   `0x1681195C176239ac5E72d9aeBaCf5b2492E0C4ee`).
2. **Curve stableswap-NG** for two swap legs:
   - crvUSD → USDC (`0x4DEcE678...`)
   - USDC → USDe (`0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72`)
3. **Ethena sUSDe ERC-4626 vault** (`0x9D39A5DE30e57443BfF2A8307A4256c8797A3497`)
   — USDe is staked into sUSDe, which appreciates via Ethena's funding
   yield (~10% APR at fork).
4. **Morpho Blue sUSDe/USDC market** (LLTV 91.5%, Gauntlet/MEV Capital
   oracle `0x5D916980D5Ae1737a8330Bf24dF812b2911Aae25`) — collateralise the
   sUSDe shares and recycle the borrowed USDC into more USDe → sUSDe in 3
   loops.

## Why it composes

The WETH staying as LLAMMA collateral keeps its ETH price exposure
(useful when running this as a delta-neutral ETH ladder) while the *cash*
leg of the structure (the crvUSD borrow) is recycled into sUSDe-Morpho
carry. The composition has two stacked yield surfaces:

- LLAMMA collateral side: zero yield (WETH idle), but the borrower is
  short crvUSD-rate which on the WETH market trades at ~6%.
- Morpho sUSDe loop: long sUSDe NAV (~10%), short Morpho USDC borrow
  rate (~7%).

Net carry = `lev_morpho * (sUSDe_apr - morpho_usdc_apr) - crvusd_borrow_rate`
on the levered notional.

## Preconditions

- WETH market has free debt ceiling at the fork (~$45M open at block
  20_650_000).
- Curve USDe/USDC pool has > $20M of USDC inventory to absorb the seed.
- Morpho sUSDe/USDC 91.5% market is active and has spare lending capacity.

## Strategy steps

1. Deposit 200 WETH as LLAMMA collateral; borrow 50% of `max_borrowable`
   in crvUSD.
2. crvUSD → USDC (Curve stableswap-NG idx 0→1).
3. USDC → USDe (Curve idx 1→0, the seed leg).
4. `sUSDe.deposit(usdeOut, address(this))` — receive shares.
5. `morpho.supplyCollateral(sUSDe_shares)`.
6. Loop ×3:
   - Compute headroom = `collateralUSDC * LLTV_915 - debt`.
   - `morpho.borrow(0.85 * headroom)` USDC.
   - USDC → USDe (Curve).
   - sUSDe.deposit → shares.
   - supplyCollateral.
7. Warp 30 days; `morpho.accrueInterest`. Print position state.

## PnL math

Let `M_lev` = effective Morpho leverage (~5.4× at 3 loops, 85% per-loop
LTV); `L` = LLAMMA debt expressed in USD; `P_w` = WETH principal at $2.55k
each:

```
sUSDe_yield_usd  = M_lev * L * y_sUSDe
morpho_cost_usd  = (M_lev - 1) * L * y_morpho_usdc_borrow
llamma_cost_usd  = L * y_crvUSD_borrow_weth_market
swap_drag        = ~6 * 4 bp = 24 bp on initial L, ~3 bp * 3 loops on recursion
```

At fork values (`y_sUSDe=10%`, `y_morpho=7%`, `y_crvusd=6%`,
`L ≈ $230k`):

```
30-day net usd ≈ (5.4*230k*0.10 - 4.4*230k*0.07 - 230k*0.06) * 30/365
              ≈ ($124k - $71k - $13.8k) * 30/365 * (1/12)   <-- pure annualised
              ≈ ~$40k/year * 30/365 ≈ +$3,290 over 30 days
```

minus ~$40-80 swap drag on the entry, minus accrued LLAMMA fee.

## Block pinned

**20_650_000** (Sep 2024). sUSDe APR > Morpho USDC borrow rate; crvUSD
WETH-market borrow rate ~6%.

## Risks

- **sUSDe NAV reversal.** Ethena's funding yield can flip negative for
  multi-day windows; the loop loses *3.4×* on the negative leg.
- **Morpho LLTV vs sUSDe price.** The Morpho oracle uses sUSDe's
  `convertToAssets`; a smart-contract event (Ethena cooldown, oracle
  freeze) prevents withdrawal and forces a liquidation cascade.
- **LLAMMA soft-liq.** A 15% ETH drawdown moves the WETH-market price
  oracle through the loaned bands and converts WETH→crvUSD inside the
  position; user keeps the debt but loses ETH directional exposure.
- **Curve USDe/USDC depeg.** A ≥30 bp depeg on the entry leg eats most
  of the 30-day carry.

## Result

Status: **theoretical**. Expected 30-day net on $510k WETH principal:
**+$2,000 to +$4,500**, net of gas (~700k gas at 15 gwei).
