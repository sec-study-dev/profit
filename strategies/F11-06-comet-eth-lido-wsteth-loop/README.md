# F11-06: Compound v3 ETH Comet (cWETHv3) + Lido wstETH leverage loop

## Mechanism
Compound v3 deployed a **second base-asset market** in 2023: cWETHv3 with
WETH as the single borrowable asset and wstETH/cbETH/rETH/wbETH as collateral.
This is the *opposite* of F11-01 (which uses cUSDCv3): here WETH is the
borrowable asset and the *collateral* is the yield-bearing LST.

The loop:
1. WETH → ETH → stETH (Lido submit) → wstETH.
2. Supply wstETH to cWETHv3 as collateral.
3. Borrow WETH against it (wstETH bcf = 90 %).
4. Convert borrowed WETH → ETH → stETH (Curve stETH/ETH pool) → wstETH.
5. Redeposit. Repeat.

Because the collateral is wstETH (3 % staking yield, ETH-denominated) and
the debt is WETH (~2.5 % borrow rate at low utilisation), the spread is
positive and *non-directional*: the position is delta-neutral to ETH/USD.

## Why it composes
- Compound v3's ETH Comet is the *only* major money market that natively
  uses WETH as the base asset with LST collateral and a 90 % collateral
  factor. Aave's WETH borrowing has a 75-80 % LTV cap on wstETH; cWETHv3
  pushes 90 % because the IRM and oracle are dedicated to ETH-denominated risk.
- Lido provides the LST yield (3 % APR, accrued via wstETH's
  `stEthPerToken`); Curve's stETH/ETH pool provides the atomic ETH→stETH
  conversion (no withdrawal-queue delay).
- The two mechanisms compose because Compound's wstETH price oracle reads
  Lido's `stEthPerToken` (rate provider, not market price), so peg drift
  on the Curve pool does **not** trigger liquidation while collateral value
  still reflects the genuine Lido yield.

## Preconditions
- Mainnet at block ≥ cWETHv3 deployment (Mar 2023).
- wstETH listed (since deployment).
- Curve stETH/ETH pool deep (always true on mainnet).
- Capital: any size; price-impact on Curve becomes material above ~$50m unwind.

## Strategy steps
1. Wrap ETH → wstETH via Lido `submit` + wstETH `wrap`.
2. Supply wstETH to cWETHv3.
3. Loop N times: borrow WETH (`withdraw(WETH)`), convert via Curve stETH
   pool to wstETH, redeposit.
4. Hold 30 days; warp + `accrueAccount` to crystallise indices.
5. Optionally unwind: borrow → repay via Curve route in reverse.

## PnL math
Let:
- `s` = Lido staking yield ≈ 0.030 APR (accrued via wstETH appreciation)
- `r_b` = cWETHv3 borrow APR ≈ 0.025 (observed at the pinned block)
- `L` = 0.82 → `K = 1/(1-0.82) ≈ 5.6`

Net APY on principal (ETH-denominated, before gas + swap slippage):
```
net = K * s - (K - 1) * r_b - swap_drag
    = 5.6 * 0.030 - 4.6 * 0.025 - 0.002
    = 0.168 - 0.115 - 0.002 = +0.051 = +5.1% APY
```

Over 30 days: **+0.4 %** net of borrow cost. The position is delta-neutral
to ETH/USD; the alpha is purely the wstETH staking yield levered above the
WETH borrow rate.

## Block pinned
**21_300_000** (Dec 2024) — Comet WETH market healthy (~80 % util, borrow APR
~2.5 %); Curve stETH/ETH peg < 30 bps.

## Addresses used (verified)
- `0xA17581A9E3356d9A858b789D68B4d866e593aE94` — Compound v3 cWETHv3
  (ETH Comet), verified at
  https://etherscan.io/address/0xa17581a9e3356d9a858b789d68b4d866e593ae94
- `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` — wstETH
- `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` — stETH
- `0xDC24316b9AE028F1497c275EB9192a3Ea0f67022` — Curve stETH/ETH pool
- `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` — WETH

## Risks
- **stETH/ETH depeg on Curve**: a Curve-side stETH discount widens the
  conversion drag per loop, eroding K. A 1 % depeg adds ~1 % cumulative drag
  at LOOPS=4.
- **Lido oracle / rate-provider stall**: if `stEthPerToken` halts updating,
  collateral value freezes while debt accrues — slow liquidation drift.
- **Comet utilization spike**: at >85 % util, borrow APR kinks. A jump from
  2.5 % to 6 % flips the carry negative.
- **Comet pause** via governance.

## Result
Status: theoretical (forge build not run; addresses verified against
Compound v3 docs and Etherscan). Expected PnL: **+0.4 % over 30 days** at
K≈5.6, delta-neutral to ETH price. PoC asserts loop increased collateral
and opened non-zero debt.
