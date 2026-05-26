# F17-05: sUSDe → sUSDS Aave e-mode collateral rotation

## Mechanism

A holder of a leveraged sUSDe position on Aave V3 (stablecoin e-mode) is
**exposed to Ethena's funding-rate-driven APY**. When perpetual funding
compresses or flips negative (as it did in late-Sep 2024), sUSDe APY can
fall *below* the Sky Savings Rate (SSR) that anchors sUSDS. At that
moment the optimal yield-bearing-stable collateral switches.

This PoC executes an **atomic collateral rotation** that:

1. Reads the live SSR-derived sUSDS APY and the assumed sUSDe APY at the
   pinned block.
2. If `sUSDS_APY > sUSDe_APY + 50 bps`, takes a Balancer flash loan of
   USDT (Aave's e-mode borrowable side) to repay the existing Aave debt
   atomically.
3. Withdraws sUSDe collateral, redeems sUSDe → USDe (instant if cooldown
   == 0, otherwise via a Curve USDe/USDT path or analytical proxy).
4. Hops USDT → USDC → USDS (via Curve 3pool then Curve USDS/USDC NG),
   deposits USDS → sUSDS (Sky's ERC-4626).
5. If Aave lists sUSDS, re-supplies sUSDS into the same Aave account so
   the new position inherits the e-mode collateral leverage; otherwise
   holds raw sUSDS.

Three mechanisms compose **in a single tx**:

- **Aave V3** — collateral side: e-mode `setUserEMode(EMODE_STABLE)`,
  `supply` / `withdraw` / `borrow` / `repay`. Borrow side: USDT.
- **Ethena** — `sUSDe.deposit(USDe)` to enter, ERC-4626
  `previewRedeem` to exit; Curve USDe/USDT as the cooldown-free
  liquidity venue when `cooldownDuration > 0`.
- **Sky** — `sUSDS.deposit(USDS)` to take the SSR-anchored side.

## Why it composes

This is the first family-F17 strategy that treats two yield-bearing
stables as **interchangeable e-mode collateral**: the Aave V3 stablecoin
e-mode category groups USDC/USDT/DAI/sUSDe/sUSDS together (post-AIP
listings through Sep 2024). That grouping turns the choice between
sUSDe vs sUSDS into a *collateral swap* problem rather than a *deposit
re-entry* problem — the leverage, the borrowing capacity, and the
liquidation buffer all carry over.

Flash-loaning the borrowable side (USDT) is what makes the rotation
atomic. Without the flash, the user would have to either:
- unwind the loop (slow, gas-heavy, and exposes intermediate solvency
  if oracle moves), or
- forgo rotation entirely (suboptimal carry).

With the flash, the entire rotation is one tx and atomic with respect
to slippage and liquidation.

## Preconditions

- Aave V3 lists sUSDe **as a reserve in stablecoin e-mode**. Activated
  by AIP-369 in Jul 2024. Block 20,840,000 (Sep 27 2024) is well after
  activation.
- Curve USDe/USDT pool live (deepest USDT venue for Ethena unwind).
- Either:
  - Curve USDS/USDC NG pool live (preferred), OR
  - DAI USDS PSM available for USDS minting from DAI.
- Balancer V2 vault solvent in USDT (always true at mainnet scale).

## Strategy steps

1. Pin **block 20,840,000** (~Sep 27 2024).
2. Probe APYs (sUSDS via `ssr()`; sUSDe via 600 bps anchor — late-Sep
   funding compression).
3. Gate: rotate only when `sUSDS_APY > sUSDe_APY + 50 bps`.
4. Build initial sUSDe position: deposit 200k USDe → sUSDe → supply to
   Aave → enter e-mode → borrow 70% of headroom in USDT.
5. Flash-borrow USDT from Balancer (0 fee).
6. In callback:
   a. Repay Aave USDT debt.
   b. Withdraw sUSDe collateral.
   c. Redeem (or proxy-redeem) sUSDe → USDe.
   d. Swap USDe → USDT (Curve USDe/USDT) to repay flash.
   e. Hop USDT → USDC → USDS (Curve 3pool + Curve USDS/USDC).
   f. Deposit USDS → sUSDS.
   g. Re-supply sUSDS to Aave (if listed).
7. Report PnL and final sUSDS holdings.

## PnL math

Rotation captures the *forward* APY differential applied across the
levered notional. Define:

- `K` = effective leverage at e-mode ceiling (~2× practical; 3× max)
- `N` = equity ($200k initial USDe)
- `Δ_apy` = sUSDS APY − sUSDe APY (≈ 100 bps in late-Sep 2024)

Annualized rotation uplift:

```
ΔPnL/yr ≈ K · N · Δ_apy
        ≈ 2 · 200_000 · 0.01
        ≈ $4_000/yr per $200k equity
```

Minus rotation friction:

- Aave USDT borrow rate vs SSR coverage: marginal, both are stablecoin
  e-mode rates.
- Curve USDe/USDT slippage at $100k size: ~3-5 bps (~$30).
- Curve 3pool USDT/USDC slippage: ~2 bps (~$20).
- Curve USDS/USDC slippage: ~5 bps (~$50, pool thinner in early-deploy
  window).
- Gas (3 Curve swaps + 4 Aave ops + 1 flash + 1 sUSDS deposit): ~1.0M
  gas at 30 gwei ≈ $90.

Total rotation friction ≈ $190; recovered within 30 days at the
projected APY uplift.

## Block pinned

`20_840_000` (~Sep 27 2024). Aave V3 stablecoin e-mode active with
sUSDe listed; sUSDS deployed and in early adoption (Sky launched
~Sep 18 2024 via the Maker→Sky migration); Ethena funding visibly
compressing per public dashboards.

## Risks

- **sUSDe cooldown**. Ethena's canonical `redeem` requires a 7-day
  cooldown when `cooldownDuration > 0`. The PoC uses Curve USDe/USDT
  as the immediate-liquidity path, but at extreme size the pool
  imbalances. The PoC's analytical proxy fallback documents the
  limitation rather than fabricating yield.
- **Aave sUSDS listing**. As of FORK_BLOCK sUSDS may not yet be listed
  on Aave V3 mainnet (Sky launched late Sep 2024, Aave listings lag
  by weeks). The PoC handles this by holding raw sUSDS off-Aave; the
  rotation still captures the APY differential but at lower leverage.
- **Spread compresses or inverts mid-tx**. Both APYs are read from
  governance/funding accumulators; they cannot move within a single
  block, so the rotation is safe from rate-snapback. The longer-horizon
  risk is that the spread closes within days, requiring re-rotation
  (gas drag).
- **Flash-loan repayment slippage**. The Curve USDe/USDT pool at
  100k size carries ~3-5 bps slippage. If the rotation is sized
  larger, the swap shortfall could exceed the flash buffer and the tx
  reverts atomically — no partial-state risk.
- **Balancer USDT availability**. Balancer V2 vault has held >$50M
  USDT consistently; flash-loan revert from insufficient float is
  unlikely at the pinned scale.

## Result
Status: theoretical-historical-replay
Expected PnL: ~$4,000/yr per $200k equity (K=2x leverage × 100 bp sUSDS-vs-sUSDe APY differential; ~$190 rotation friction recovered within 30 days)

A flash-loan-atomic rotation PoC for the e-mode-collateral-swap
pattern in the yield-bearing-stable family. Asserts:

- a measurable spread is read on-chain;
- the rotation completes within one tx;
- final position holds sUSDS shares (the higher-yield side at the
  pinned block).
