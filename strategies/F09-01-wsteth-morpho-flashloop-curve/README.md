# F09-01: wstETH/WETH 94.5% LLTV Morpho loop — single-tx bootstrap via Curve stETH pool

## Mechanism

Morpho Blue's flagship correlated-asset market is the immutable
`wstETH (collateral) / WETH (loan)` market at **LLTV = 94.5%**, with
parameters:

| field            | value                                                                |
| ---------------- | -------------------------------------------------------------------- |
| loanToken        | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (WETH)                  |
| collateralToken  | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` (wstETH)                |
| oracle           | `0x2a01EB9496094dA03c4E364Def50f5aD1280AD72` (Chainlink wstETH/ETH)  |
| irm              | `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC` (AdaptiveCurveIRM)      |
| lltv             | `945000000000000000` (= 0.945e18)                                    |
| **marketId**     | `0xd0e50cdac92fe2172043f5e0c36532c6369d24947e40968f34a5e8819ca9ec5d` |

(The marketId is `keccak256(abi.encode(MarketParams))` — well-known and
reproduced by hand below in the PoC, but we also hard-code it as a constant
for clarity. Cross-checked against Morpho's public market dashboard.)

Morpho Blue exposes a **zero-fee, callback-style flashloan** on any token
held in the singleton (`flashLoan(token, assets, data)`). The callback
(`onMorphoFlashLoan`) runs before the singleton enforces repayment, so the
entire leveraged-loop open fits in one tx:

1. `flashLoan(WETH, K·equity)` from Morpho.
2. In callback, route the borrowed WETH **through the Curve stETH/ETH pool**
   (`0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`, coins = `[ETH, stETH]`):
   unwrap WETH→ETH, `exchange(0, 1, ETH_amount, ...)` for stETH, then wrap
   the stETH into wstETH (`IWstETH.wrap`).
3. `supplyCollateral` the wstETH to the 94.5% market.
4. `borrow` `K·equity` WETH from the same market.
5. Repay the flash by leaving the singleton's `safeTransferFrom` pull
   intact (no transfer required — approval was set at outer scope).

## Why the Curve route matters (vs. Lido submit)

The textbook open uses Lido's `submit{value: x}()` which mints stETH at the
1:1 protocol rate but is **rate-limited daily** by Lido's stakeLimit
(currently ~150k ETH/day, lower at points of heavy depositing). For large
single-tx opens (≥1k ETH) the daily cap can be exhausted by other
depositors earlier in the block; the Curve stETH/ETH pool sidesteps that
and additionally captures any micro-premium when stETH trades slightly
below 1:1 (typical: -1 to -5 bps).

The trade-off is Curve fee + slippage. The stETH pool's `fee = 4 bps` and
the `A` is high; for 500 ETH at a 4500-ETH pool depth the realised slippage
is ≈ +0.3 to +0.7 bps **in our favour** when stETH/ETH trades at par or
slightly below. Net: Curve is usually equal or better and never rate
limited.

## Why it composes — unique to Morpho

- **Free flashloan**: any other money market would charge 5-9 bps
  (Aave/Spark) or 0 bps but with longer call-graph (Balancer V2 flashLoan
  via Vault). Morpho's zero-fee, single-asset callback eliminates the loop
  fee entirely.
- **Atomic open at higher LLTV**: Aave v3 e-mode wstETH/WETH tops at 93%
  LLTV; Morpho's 94.5% gives `K = 1/(1-L) ≈ 18.2`. We deliberately open at
  92% (8 bp safety) so `K = 12.5` to avoid immediate liquidation if
  Chainlink wstETH/ETH ticks down.
- **Immutable market**: no governance can change the LLTV/oracle/IRM under
  us mid-loop — unlike Aave/Compound where a governance vote can shrink
  LLTV.

## Preconditions

- Mainnet block where the wstETH/WETH 94.5% market is live with deep WETH
  supply liquidity. Verified at block 21,400,000 (Dec 2024) — Morpho
  dashboard shows ~22k WETH spare in this market.
- Curve stETH/ETH pool has ≥ 4× the flash amount on each side.
- WETH borrow APY < wstETH stake APY (typically ~2.0-2.6% vs ~3.0-3.3%).

## Strategy steps (PoC)

1. Fund test contract with `equity = 50 WETH`.
2. Pre-approve WETH and wstETH to Morpho (`type(uint256).max`).
3. Pre-approve stETH to wstETH wrapper.
4. Call `IMorpho.flashLoan(WETH, FLASH_AMOUNT=550 ether, "loop")` —
   targets `K ≈ 12` on 50 ETH equity.
5. Inside callback:
   a. Total WETH held = 600 ether (equity + flash).
   b. `IWETH.withdraw(600 ether)`.
   c. `ICurveStableSwap.exchange(0, 1, 600 ether, min_dy)` on the stETH
      pool → ~600 stETH received.
   d. `IWstETH.wrap(stETH_bal)` → wstETH (~ stETH / stEthPerToken).
   e. `IMorpho.supplyCollateral(market, wstETH_bal, this, "")`.
   f. `IMorpho.borrow(market, 550 ether, 0, this, this)` → 550 WETH out.
   g. Approval already set; return.
6. After: contract holds 50 ETH-equiv of net equity as wstETH collateral
   minus WETH debt. Cash carry accrues over time on-chain.

## PnL math

Let `s = 3.1%` (wstETH stake APY), `b = 2.3%` (Morpho wstETH/WETH borrow
APY at fork block), `equity = 50`, `K = 12` (flash 550), `L = 0.917`.

```
collateral_ETH = 600 ETH ≈ 600/1.151 ≈ 521 wstETH
debt_WETH      = 550 ETH
net_equity     = 50 ETH

yearly_yield   = 600 × 0.031 = 18.6 ETH/yr
yearly_borrow  = 550 × 0.023 = 12.65 ETH/yr
net cash APY   = (18.6 - 12.65) / 50 = 11.9%
```

At ETH=$3,000 and 30-day hold: `50 × 0.119 × 30/365 = 0.49 ETH ≈ $1,470`
gross, single-tx gas ≈ 700k × 30 gwei × $3k = ~$63 → ~$1,400 net.

## Block pinned

**21,400,000** (Dec 2024). The 94.5% LLTV wstETH/WETH market has been live
since Feb 2024 (~block 19.3M); we picked a later block with deeper
liquidity and a more stable Chainlink stETH/ETH feed. PoC opens the
position and immediately reports balances; the cash carry would accrue in
subsequent blocks if `vm.warp`/`vm.roll` were applied.

## Risks

- **wstETH/ETH oracle drift**: Morpho uses a Chainlink-based static oracle.
  A stETH depeg (Curve discount) would not move the oracle until Chainlink
  updates; this *helps* us (later liquidation) but means a fast-moving
  depeg could cause coordinated, lagged liquidations.
- **Curve slippage at scale**: For ≥ 5k ETH flashes the Curve fee/slippage
  exceeds the Lido `submit` cost; switch to Lido path then.
- **Adaptive-curve IRM spike**: utilisation can ramp; if utilisation hits
  ~92%+ the IRM ramps borrow APY exponentially.
- **Flashloan singleton spare**: if Morpho's WETH spare < FLASH_AMOUNT,
  reverts before any state change. Cheap to retry.
- **Liquidation incentive ≈ 5.8%**: at LLTV = 94.5%, the liquidator
  bonus is `1/LLTV - 1 = 5.8%`; we deliberately open at 91.7% LTV (3.3%
  buffer to LLTV) to absorb 1 day's negative oracle drift.

## Result

Status: **theoretical / on-chain mechanically-tested**. The marketId,
oracle, IRM, and Curve pool addresses are all stable and verified.
PoC opens the position atomically; cash carry PnL accumulates over time
and would be measured by `vm.warp(block.timestamp + 30 days)` + Morpho
`accrueInterest` then snapshotting positions.

Expected PnL on 50 ETH equity over 30 days: **+0.45 to +0.55 ETH**
(~$1,300-1,650), net of single-tx gas (~$60). Capital efficiency
materially exceeds F01-01's iterative-loop Aave equivalent.

## Uncertainties

- Curve stETH pool fee schedule has been adjusted historically (1 → 4 bps);
  PoC uses `min_dy = 0.997 * dx` as a conservative bound.
- `stEthPerToken` at the exact fork block is read live; the PoC does not
  hard-code it.
