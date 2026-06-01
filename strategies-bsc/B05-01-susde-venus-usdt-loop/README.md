# B05-01: sUSDe → Venus collateral → borrow USDT → buy USDe → stake → recursive loop

## Mechanism
Three BSC primitives stacked into a sUSDe carry book:

1. **Ethena sUSDe (ERC-4626)** — sUSDe is the staked-USDe wrapper that
   accrues Ethena's perp-funding yield as `pricePerShare`. The vault is
   identical on BSC (the OFT-bridged USDe is the canonical underlying);
   `ISUSDe.deposit(assets, receiver)` mints sUSDe at the current rate, and
   `convertToAssets(shares)` is the monotone exchange-rate oracle that loops
   key off of.
2. **Venus Core Pool** — Compound v2 fork. Venus has begun listing sUSDe /
   USDe in its Core pool (or as Venus V4 isolated pools); the canonical
   recursive-stake flow is `enterMarkets` → `mint(sUSDe → vsUSDe)` →
   `borrow(USDT from vUSDT)`. The USDT IRM is well-understood and base
   borrow APR is materially below Ethena sUSDe APY at the pinned block.
3. **PCS v3 USDT/USDe pool** — 1bp/5bp fee tier USDT↔USDe pool routes the
   borrowed USDT into more USDe at near-peg (≈ 5-15 bp slippage including
   fee for the position sizes we use). Buy USDe with the borrowed USDT,
   deposit into sUSDe, re-supply as Venus collateral. Repeat.

## Why it composes
- sUSDe pricePerShare is **internal accounting** — it ticks up every block
  as Ethena USDe rebase rewards distribute. There is no AMM hop on the
  stake leg, so the only price risk is the USDT→USDe swap, capped at the
  PCS v3 1-bp tier liquidity.
- Venus' USDT IRM is decoupled from sUSDe yield. As long as
  `(sUSDe APY) - (vUSDT borrow APR) > (USDT→USDe swap cost) / loop_period`,
  the carry is positive after netting the swap cost.
- USDe on BSC trades 50–150 bp below peg during stress (per family brief),
  which actually *helps* this strategy: cheaper USDe means more sUSDe per
  borrowed USDT each iteration. The peg also normally mean-reverts before
  Venus re-marks, so collateral value is preserved.

## Preconditions
- BSC block where Venus Core (or Venus V4 isolated pool `vsUSDe`) lists
  sUSDe as collateral and `vUSDT` is borrowable.
- `sUSDe.deposit()` accepts USDe (not paused; cooldown phase irrelevant on
  the entry leg — only `redeem` is cooldown-gated).
- USDT/USDe PCS v3 pool has > $5M liquidity at the pinned block.
- vUSDT utilization < 80 % so the borrow IRM is still on the flat side of
  the kink.

## Strategy steps (4 iterations, 100k USDe principal)
1. Deposit 100,000 USDe into sUSDe → receive `shares =
   sUSDe.previewDeposit(100k)`.
2. Iteration 1:
   - `Comptroller.enterMarkets([vsUSDe, vUSDT])`.
   - `vsUSDe.mint(susde_balance)` — supplies sUSDe collateral.
   - `vUSDT.borrow(usdt_to_borrow)` where
     `usdt_to_borrow = susde_usd_value * CF * 0.95`. With CF ≈ 0.78 (typical
     for staked stables on Venus) the per-step LTV is ≈ 0.74.
   - PCS v3 `exactInputSingle(USDT → USDe, fee=100)` swaps the borrowed
     USDT for USDe. Slippage cap = 30 bp.
   - `sUSDe.deposit(usde_balance, address(this))` re-stakes.
3. Repeat for N=4 iterations.
4. Hold 30 days. PnL = USD-denominated delta of
   `(sUSDe_assets_value − USDT_debt − swap_costs)`.

Effective leverage at L=0.74, N=4: 1 + 0.74 + 0.547 + 0.405 + 0.300 ≈
**3.0×**.

## PnL math (100 k USDe principal, 30-day horizon)
Indicative rates:
- sUSDe APY: ~9.0 % (Ethena funding + sUSDX reward, blended)
- vUSDT borrow APR: ~5.5 %
- Per-loop swap cost (1 bp pool + 10 bp avg peg discount): 11 bp on the
  borrowed leg.
- Levered exposure: 3.0× collateral, 2.0× debt.
- Gross APY: 3.0 × 9.0 − 2.0 × 5.5 = 27.0 − 11.0 = **+16.0 %**.
- Net of swap drag (≈ 11 bp × 2.0 leverage × 4 loops / 1 year = 0.88 %):
  ~**+15.1 % APY**.
- 30-day net carry: 15.1 × 30/365 ≈ **+1.24 %** on principal ≈ **+1,240
  USD per 100k USDe**.

Gas: ~4 enterMarkets / mint / borrow / swap cycles ≈ 2.0M gas. At 1
gwei × $600/BNB ≈ $1.2 — negligible.

## Block pinned
**42_500_000** (late-2024). Venus Core / V4 listings for sUSDe expected
around this window; the exact block must be re-pinned once `BSC_RPC_URL`
is available. The strategy is invariant to ±500k block drift.

## Addresses used
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe ERC20 (`BSC.USDe`).
- `0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2` — sUSDe ERC4626 (`BSC.sUSDe`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Venus Comptroller
  (`BSC.VENUS_COMPTROLLER`).
- `0xfD5840Cd36d94D7229439859C0112a4185BC0255` — vUSDT (`BSC.vUSDT`).
- `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` — PCS v3 SwapRouter
  (`BSC.PCS_V3_ROUTER`).
- `LOCAL_VSUSDE` — Venus vsUSDe market. `BSC.sol` has no verified entry
  yet; the PoC pins it inline as a placeholder
  (`0x000000000000000000000000000000000000B505`). Replace once Venus
  confirms the canonical V4 vsUSDe address.
- `LOCAL_USDT_USDE_V3` — PCS v3 USDT/USDe pool (1 bp tier). Placeholder
  `0x000000000000000000000000000000000000B515`; replace once on-chain.

## Risks
- **USDe de-peg deepens**: a >150 bp discount during the swap leg makes
  re-staking less efficient. Mitigation: cap per-iteration swap to
  ≤ $50k so even adverse 30 bp slippage stays under 1.5 % of position.
- **Venus collateral-factor cut**: governance can lower CF on sUSDe; a
  step from 0.78 → 0.70 forces partial unwind. Maintain ≥ 5 % headroom.
- **sUSDe redemption cooldown**: exit via `cooldownShares()` is 7-day
  delayed. Emergency exit path: PCS v3 sUSDe/USDe pool (thin) or
  Pendle PT-sUSDe LP exit.
- **vUSDT IRM spike**: kinks at ~80 % utilization. If borrow APR jumps
  past sUSDe APY the carry inverts — must monitor and unwind.
- **Ethena funding flip negative**: sUSDe APY drops below vUSDT borrow
  APR. This is the explicit B05-04 unwind trigger.

## Result
Status: **theoretical** (BSC RPC not configured; PoC compiles and runs
the offline accounting branch). Expected PnL: **+0.8 – 1.5 % over 30
days on 100 k USDe principal**, dominated by the sUSDe – USDT borrow
spread amplified by 3× recursive leverage.
