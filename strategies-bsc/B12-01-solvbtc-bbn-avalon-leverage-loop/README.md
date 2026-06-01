# B12-01: solvBTC.BBN → Avalon collateral → borrow USDX → buy more solvBTC.BBN → recursive loop

## Mechanism
Three BSC primitives stacked into a BTC-restake carry book:

1. **Solv solvBTC.BBN (Babylon-restaked BTC-LSD)** — solvBTC.BBN is the
   Babylon-restaked wrapper on top of solvBTC. The underlying solvBTC is
   backed 1:1 by BTCB/wBTC reserves; solvBTC.BBN re-stakes those reserves
   into Babylon's BTC-staking layer and accrues a baseline Babylon yield
   (assumed 3-5 % APR at the pinned block, denominated in BTC). The token
   non-rebases — value accrues via slow `pricePerShare`-style appreciation
   plus a points/incentive component paid out off-chain.
2. **Avalon Lending Pool (Aave V3 fork, BTC-LSD focused)** — Avalon lists
   solvBTC.BBN as collateral and USDX (Avalon's stable) as borrowable.
   LTV for solvBTC.BBN sits around 70 % (Aave-V3-style configuration). The
   `supply` / `borrow` flow is identical to the Aave V3 ABI mirrored in
   `IAvalonLendingPool`. Avalon further pays incentive emissions
   (AVAL or USDX rebates) on solvBTC.BBN supply, which stacks on top of
   the Babylon yield.
3. **PCS v3 USDX / BTCB (or USDX / USDT → BTCB)** — the borrowed USDX is
   routed via a two-hop swap (USDX → USDT → BTCB) on PCS v3, then BTCB is
   sent through the Solv mint path (`solvBTC.deposit(BTCB)` →
   `solvBTC.BBN.stake(solvBTC)`) to mint fresh solvBTC.BBN, which is
   re-supplied as Avalon collateral. Repeat.

## Why it composes
- solvBTC.BBN appreciation is **internal Babylon yield** that does not need
  an AMM hop on the stake leg — only the USDX → BTC swap touches an AMM.
- Avalon's USDX borrow APR (assumed 4-5 %, plus its own incentive offset)
  is decoupled from Babylon yield, so leverage amplifies the
  `BabylonAPY + AvalonSupplyIncentive − UsdxBorrowAPR − SwapCost` spread.
- The USDX borrow itself enjoys an Avalon emission that often *negates*
  most of the nominal borrow APR — at the pinned block we assume net
  effective borrow cost ≈ 1.5 % APR.

## Preconditions
- BSC block where Avalon Lending Pool has solvBTC.BBN listed as
  collateral with LTV ≥ 65 %, and USDX borrow IRM is below kink.
- Solv solvBTC + solvBTC.BBN mint paths are open (not in a freeze /
  whitelist-only state); fall back to PCS v3 secondary-market buy if the
  primary mint is gated.
- USDX / USDT PCS v3 pool has > $5M liquidity; BTCB/USDT 1bp or 5bp tier
  available.

## Strategy steps (4 iterations, 10 BTC principal)
1. Pre-fund 10 BTC worth of solvBTC.BBN (entry: market buy via PCS v3 or
   direct Solv mint).
2. Iteration 1:
   - `IAvalonLendingPool.supply(solvBTC.BBN, balance, address(this), 0)`.
   - Read `getUserAccountData` → `availableBorrowsBase`, take 90 % as
     borrowable USDX notional (`borrow_usdx = availableBorrowsBase * 0.90`).
   - `IAvalonLendingPool.borrow(USDX, borrow_usdx, 2 /*variable*/, 0,
     address(this))`.
   - PCS v3 swap USDX → BTCB (path: USDX → USDT → BTCB, 1 bp + 5 bp tiers).
     Slippage cap = 30 bp.
   - Mint solvBTC then solvBTC.BBN via Solv routers (or PCS v3 buy of
     solvBTC.BBN directly if mint gated).
3. Repeat for N=4 iterations.
4. Hold 30 days. PnL = USD-denominated delta of
   `(solvBTC.BBN_assets_value − USDX_debt − swap_costs)`.

Effective leverage at LTV=0.65, N=4: 1 + 0.65 + 0.4225 + 0.275 + 0.179 ≈
**2.53×** collateral exposure.

## PnL math (10 BTC principal, 30-day horizon, BTC=$65k)
Indicative rates:
- Babylon yield on solvBTC.BBN: ~4.0 % APR (BTC-denominated).
- Avalon supply incentive on solvBTC.BBN: ~2.0 % APR (in USDX/AVAL).
- Avalon USDX borrow APR net of incentives: ~1.5 %.
- Per-loop swap cost (USDX→USDT→BTCB, 1bp + 5bp tiers + 5 bp peg drag):
  11 bp on the borrowed leg.
- Levered collateral: 2.53×; net debt: 1.53×.
- Gross APY: 2.53 × (4.0 + 2.0) − 1.53 × 1.5 = 15.18 − 2.30 = **+12.88 %**.
- Net of swap drag (≈ 11 bp × 1.53 leverage × 4 loops / year ≈ 0.67 %):
  ~**+12.2 % APY**.
- 30-day net carry: 12.2 × 30/365 ≈ **+1.00 %** on principal ≈
  **+6,500 USD per 10 BTC** ($650,000 notional).

Gas: ~4 supply / borrow / swap / mint cycles ≈ 2.5M gas. At 1 gwei × $600/BNB
≈ $1.5 — negligible.

## Block pinned
**46_000_000** (late-2024 / early-2025). Avalon launched on BSC mid-2024;
solvBTC.BBN listing expected in the Q4-2024 window. The strategy is
invariant to ±500k block drift.

## Addresses used
- `0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c` — BTCB (`BSC.BTCB`).
- `0x4aae823a6a0b376De6A78e74eCC5b079d38cBCf7` — solvBTC (`BSC.solvBTC`).
- `0x1346b81C8E3FE38d6cFc7e1B1cdF92C6b0050BFE` — solvBTC.BBN
  (`BSC.solvBTC_BBN`).
- `0xf9278C7c4aEfaC4dDfd0d496f7a1c39Ca6BcA6d4` — Avalon Lending Pool
  (`BSC.AVALON_LENDING_POOL`, marked `TODO verify`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` — PCS v3 SwapRouter
  (`BSC.PCS_V3_ROUTER`).
- `LOCAL_USDX` — Avalon USDX stable. **`BSC.sol` does not list USDX**;
  the PoC pins it as a `LOCAL_` placeholder
  (`0x0000000000000000000000000000000000B12001`). Replace once Avalon
  confirms canonical USDX address (rumored
  `0xf3527ef8de265eaa3716fb312c12847bfba66cef` per Avalon docs — `TODO verify`).
- `LOCAL_SOLV_BBN_MINTER` — Solv solvBTC.BBN router (mint solvBTC →
  solvBTC.BBN). Placeholder until Solv confirms canonical address.

## Risks
- **Avalon address skew**: `AVALON_LENDING_POOL` is marked `TODO verify`
  in `BSC.sol`. PoC guards with `try/catch`; production must repin.
- **USDX de-peg widens**: a >100 bp discount during the swap leg makes
  re-staking less efficient. Mitigation: cap per-iteration swap to
  ≤ $200k so even adverse 50 bp slippage stays under 1 % of position.
- **Avalon LTV cut**: governance can lower LTV on solvBTC.BBN; a step
  from 0.70 → 0.60 forces partial unwind. Maintain ≥ 5 % HF headroom.
- **Babylon staking slashing**: solvBTC.BBN absorbs Babylon validator
  slash events through `pricePerShare`. Cap recursion at N=4 so worst-case
  Babylon slash ≤ 5 % does not unwind via Avalon liquidation cascade.
- **Solv mint pause**: if `solvBTC.BBN.stake` is paused, the loop reverts
  on the entry leg. Fallback to PCS v3 secondary-market buy (often
  trades at a 10-30 bp premium to mint price — eats the spread).

## Result
Status: **theoretical** (BSC RPC not configured; PoC compiles and runs
the offline accounting branch with `try/catch` around Avalon calls).
Expected PnL: **+0.8 – 1.2 % over 30 days on 10 BTC principal**,
dominated by the levered Babylon yield + Avalon emission stack net of a
small USDX borrow drag.
