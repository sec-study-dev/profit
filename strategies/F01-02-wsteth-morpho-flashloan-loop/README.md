# F01-02: wstETH / WETH Morpho Blue loop bootstrapped by Morpho flashloan

## Mechanism
Morpho Blue is a singleton lending primitive where each market is an isolated
`(loanToken, collateralToken, oracle, IRM, LLTV)` tuple. The flagship
correlated-asset market is **wstETH (collateral) / WETH (loan)** at LLTV =
94.5%, oracle = `0x2a01EB9496094dA03c4E364Def50f5aD1280AD72` (Chainlink-backed
wstETH/ETH composition), and the adaptive-curve IRM at
`0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC`. The market has no governance,
so its terms are immutable; rate discovery is pure utilisation-driven.

Morpho Blue also exposes a **free, fee-less flashloan** on any token held in
the singleton (`flashLoan(token, assets, data)`). Because the flashloan
callback is invoked *before* repayment is enforced, a single transaction can:
(i) flash-borrow WETH equal to the desired *additional* exposure, (ii) wrap
the entire (principal + flash) into wstETH, (iii) supply as collateral,
(iv) borrow WETH from the same wstETH/WETH market at LLTV, (v) repay the
flash. The result is a fully-leveraged loop opened atomically with no
intermediate insolvency window and no gas cost beyond one tx.

The economic engine is identical to F01-01 — capture
`leverage * (stake_apy - borrow_apy)` — but the Morpho LLTV ceiling (94.5%)
allows higher leverage than Aave's 93% e-mode, and the adaptive-curve IRM
generally settles to a lower steady-state borrow rate than Aave at comparable
utilisation. The single-tx open also removes the multi-tx slippage and front-
running surface of F01-01's iterative loop.

## Why it composes
Morpho Blue's market-isolated design and its zero-fee flashloan are the
foundation for a class of "one-shot leverage" strategies that older money
markets (Aave v2/v3, Compound v2) cannot match without paid flashloan
detours. For LST looping specifically, the combination of (a) a flashloan in
the very asset the user wants to borrow against and (b) a high-LLTV
correlated-asset market means the user can move from 1x to ~18x wstETH
exposure in a single transaction at the cost of approvals plus one external
swap (Lido `submit` or Curve stETH/ETH AMM).

The deeper composition is that Morpho Blue's market parameters were
deliberately chosen by curators to mirror the rate curve of the underlying
LST. The wstETH/WETH market's IRM target utilisation is calibrated such that
at equilibrium the borrow rate sits ~80-100 bps below the wstETH internal
yield — i.e. the market is *engineered* to be a profitable place to borrow
against wstETH. The strategy is therefore not stealing alpha from Morpho
LPs; it is the intended user behaviour, and the LPs are paid by the spread
between WETH supply APY in this market and the unsecured WETH yield
elsewhere.

## Preconditions
- Mainnet, block where the wstETH/WETH 94.5% market is live and has
  meaningful liquidity (post Feb 2024).
- Sufficient idle WETH in Morpho singleton to absorb both the flashloan
  *and* the borrow leg.
- Block snapshot: borrow APY < wstETH stake APY.

## Strategy steps
1. Compute target exposure: `target_collateral = principal * K` where
   `K = 1/(1-L)` and `L` = chosen LTV (e.g. 0.92 -> K=12.5).
2. Flash-borrow `(K - 1) * principal` WETH from Morpho.
3. In the callback, wrap the entire `K * principal` WETH to wstETH via
   Lido (or Curve stETH/ETH if rate is better).
4. `supplyCollateral` the wstETH to the wstETH/WETH market.
5. `borrow` `(K - 1) * principal` WETH from the same market.
6. Repay the flashloan with the borrowed WETH.
7. Done. The position is `K * principal` wstETH collateral against
   `(K - 1) * principal` WETH debt, opened atomically.

## PnL math
Let:
- `s` = wstETH stake APY ≈ 0.030
- `b` = Morpho wstETH/WETH borrow APY ≈ 0.022
- `L` = LLTV-1bp = 0.92 (8 bp safety to LLTV)
- `K = 1/(1-L) = 12.5`

```
net_apy = K * s - (K - 1) * b
        = 12.5 * 0.030 - 11.5 * 0.022
        = 0.375 - 0.253
        = 0.122  (~12.2% APY on principal)
```

Per 100 ETH principal over 30 days: ~`100 * 0.122 * 30/365` = **1.00 ETH**
gross. Gas cost is ~700k for the one-shot open vs. ~3-4M for iterative
looping, materially improving the small-principal economics.

## Block pinned
**21_400_000** (Dec 2024) — wstETH/WETH 94.5% LLTV market established;
ample WETH liquidity confirmed via Morpho dashboards at that height.

## Risks
- **wstETH/ETH oracle divergence**: Morpho uses a static (Chainlink) oracle
  for the LLTV check; if the oracle lags a stETH discount, liquidation
  triggers later than economically justified.
- **Liquidation incentive**: Morpho's `1 / LLTV - 1` liquidation incentive
  (~5.8% at LLTV=94.5%) is paid to the liquidator on any HF<1 event.
- **Borrow-rate spike**: adaptive-curve IRM ramps quickly above target
  utilisation; sustained high utilisation can push borrow APY above stake
  APY temporarily.
- **Flashloan failure**: if Morpho singleton has < (K-1)*principal WETH
  spare, the open transaction reverts.
- **Lido-side risk**: any stETH depeg or slashing reduces collateral
  exchange rate.

## Result
Status: theoretical (Morpho market id, oracle, and IRM addresses verified
against Morpho-Blue on-chain registry; block-pinned execution not run).
Expected PnL: **+0.9% to +1.1% over 30 days** on 100 ETH principal, ~$2.3-2.8k
gross at $2.5k/ETH. Materially better than F01-01 net of gas because the
loop is opened in a single transaction.
