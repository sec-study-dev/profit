# F05-05: sfrxETH/crvUSD leverage loop

## Mechanism

Three-mechanism leveraged carry trade on the **Frax-staked-ETH** crvUSD
market:

1. **Curve crvUSD sfrxETH-market LLAMMA borrow.** The borrower deposits
   sfrxETH as collateral and mints crvUSD against it. The market's
   parameters (per-collateral, verified on etherscan):
   - Controller: `0x8472A9A7632b173c8Cf3a86D3afec50c35548e76`
   - LLAMMA: `0x136e783846ef68C8Bd00a3369F787dF8d683a696`
   - Collateral: sfrxETH `0xac3E018457B222d93114458476f3E3416Abbe38F`
2. **Frax sfrxETH ERC-4626 vault.** sfrxETH auto-compounds the underlying
   frxETH validator yield + Frax governance incentive into `pricePerShare`
   — no claim leg required. Live APR at the fork was ~3.4%.
3. **Curve crvUSD/USDC stableswap-NG + Uni v3 USDC/WETH** to recycle each
   loop's borrowed crvUSD into more frxETH and finally more sfrxETH.

## Why it composes

LLAMMA's per-collateral borrow rates differ — sfrxETH market historically
trades a few basis points below the wstETH market because sfrxETH is more
volatile and less-stable as collateral (lower borrow demand at the same
debt-ceiling). When sfrxETH staking APR > sfrxETH-market crvUSD borrow APR,
levering up amplifies the spread by ~3× at four loops with 50% per-loop
LTV. Crucially the *yield mechanism* (sfrxETH PPS appreciation) is fully
on-chain and silent — no rewards claim leg, no liquid-yield slippage.

## Preconditions

- sfrxETH market has free debt ceiling (the controller's `max_borrowable`
  must return > 0 for the sized loop).
- ETH/USD ~ flat-to-down on the day: a sharp move *up* shrinks borrow
  capacity per band; a sharp move *down* triggers soft-liquidation which
  converts sfrxETH into crvUSD inside the user's bands and breaks the
  carry assumption.

## Strategy steps

1. Open initial loan: deposit 100 sfrxETH, borrow 50% of `max_borrowable`.
2. Loop ×4:
   - crvUSD → USDC (Curve idx 0→1)
   - USDC → WETH (Uni v3 0.05%)
   - WETH → ETH (`WETH.withdraw`)
   - ETH → frxETH (`FrxETHMinter.submit`, 1:1)
   - frxETH → sfrxETH (ERC-4626 `deposit`)
   - `controller.add_collateral` + `controller.borrow_more(0, x)` where x =
     50% of fresh headroom.
3. Warp 30 days. PnL is the sum of:
   - sfrxETH NAV gain on the *total* sfrxETH inside the position;
   - minus crvUSD interest accrued on total debt;
   - minus all swap fees (Curve 4 bp, Uni v3 5 bp, LLAMMA collateral-add
     fee 0 bp).

## PnL math

For loops `n=4`, per-loop LTV `r=0.5`, principal `P`, sfrxETH APR `y_s`,
crvUSD APR `y_b`:

```
effective_leverage = 1 + r + r^2 + r^3 + r^4 ≈ 1.94
net_apr            = effective_leverage * y_s - (effective_leverage - 1) * y_b
                   - swap_drag (~6 bp per loop)
```

At pinned values (`y_s = 3.4%`, `y_b = 3.0%`):

```
net_apr ≈ 1.94 * 3.4% - 0.94 * 3.0% - 4*6 bp ≈ 6.60% - 2.82% - 0.24% ≈ +3.54%
```

## Block pinned

**20_650_000** (Sep 2024) — sfrxETH market borrow rate trough; sfrxETH APR
above the prevailing crvUSD borrow APR.

## Risks

- **LLAMMA soft-liquidation.** A 12-15% ETH drawdown moves price_oracle
  through the loop's bands. Once in soft-liq the borrower's sfrxETH gets
  converted to crvUSD inside the position — debt stays, collateral is
  effectively cashed at EMA-lagged price.
- **sfrxETH PPS deviation.** Frax can route validator slashing risk into
  PPS; a fork's slashing event makes share price fall briefly.
- **Curve crvUSD/USDC pool depth.** On heavy looping the per-loop
  USDC-out gets price impact > expected.
- **Slippage on USDC->WETH.** During the 30-day warp the pool composition
  could move, but we're measuring at the close of the open leg, so it
  affects only the entry leg.

## Result

Status: **theoretical**. Expected 30-day carry on $250k notional principal
(100 sfrxETH at ~$2.55k): **+$650 to +$1,200** before gas (300k-500k gas at
15 gwei), depending on realised drag.
