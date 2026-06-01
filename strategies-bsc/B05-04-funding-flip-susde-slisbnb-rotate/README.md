# B05-04: Funding-flip rotation — sUSDe ↔ slisBNB (Ethena vs Lista BNB stake)

## Mechanism
A **positional** (not atomic) strategy that rotates between two yielding
assets based on the relative APY signal:

- When Ethena perp funding is positive and sUSDe APY ≥ slisBNB APY +
  spread_threshold, hold sUSDe.
- When Ethena funding flips negative (delta-neutral hedge cost > BTC/ETH
  basis), sUSDe APY can drop below 3 % while Lista's slisBNB staking APY
  is a steady 3.5-4.5 % (validator rewards, BNB-denominated). At that
  point rotate the position from sUSDe → BNB → slisBNB.

This is the canonical "two yield assets, different macros" rotation
trade. The novelty is **specifically** the sUSDe ↔ slisBNB pair because
it crosses the *USD-yield ↔ BNB-yield* boundary — i.e. we accept BNB
spot exposure during the rotation if the carry differential is wide
enough.

## Why it composes
- **Ethena funding** (and therefore sUSDe APY) is structurally
  uncorrelated to BNB staking APY (which is driven by BSC validator
  inflation and MEV). So one of the two yields is almost always the
  better leg. The trade is to be in whichever is paying.
- **The rotation has a hedge variant**: if we want to stay USD-neutral,
  pair the slisBNB leg with a short BNB perp on Binance Futures (off-chain
  leg). PoC keeps the simple naked-BNB version because the agent brief
  is on-chain only — but documents the hedge for downstream wave 3 use.
- Lista's slisBNB exchange-rate path is internal (no AMM hop), so
  rotating in is cheap. Rotating *out* of slisBNB has a 7-day unbond
  unless we exit on PCS v3 (typical 30 bp slippage) — so the rotation
  asymmetry needs to be priced into the threshold.

## Preconditions
- A BSC block where Ethena funding history (or its forward proxy) puts
  sUSDe APY < 3 %. On the PoC we *simulate* this by setting the modelled
  `SUSDE_APY_BPS` low; on the forked branch the agent would need an
  off-chain Ethena APY feed.
- Lista StakeManager accepts BNB deposits at the pinned block.
- PCS v3 sUSDe/USDT pool (or sUSDe/USDe pool) liquidity > $1M for the
  exit leg.

## Strategy steps (rotation event)
Initial position: 100,000 sUSDe (≈ 105,000 USD at $1.05/share).

1. Trigger: model emits `sUSDe APY = 2.5 %`, `slisBNB APY = 4.0 %`, BNB
   spot stable. Net rotation alpha: 4.0 − 2.5 = 1.5 % annualised, less
   exit cost (~30 bp on the sUSDe leg + ~5 bp on the BNB/slisBNB mint
   leg) = 1.5 − 0.35 = **1.15 % annualised carry pickup**, achieved on
   day 1 by paying the one-time exit cost.
2. Redeem sUSDe → USDe via `cooldownShares()` + `unstake()` (7-day
   cooldown). PoC uses the *fast* alternative path: swap sUSDe → USDT on
   PCS v3 directly with a 30 bp slippage budget.
3. Swap USDT → BNB on PCS v3 (5 bp pool).
4. `ListaStakeManager.deposit{value: bnb}()` → receive slisBNB.
5. Hold slisBNB for 30 days. PnL = USD-denominated delta of slisBNB
   position vs the counterfactual of holding sUSDe at 2.5 % APY.

## PnL math (100 k USDe-equivalent, 30 days)
Initial value = 100 k USDe × $0.999 = $99,900.

Counterfactual: hold sUSDe at 2.5 % APY for 30 days:
  +99,900 × 2.5 % × 30/365 = **+205 USD**.

Strategy: rotate to slisBNB.
- Exit cost (sUSDe → USDT → BNB → slisBNB chain): 30 bp + 5 bp + 0 bp
  mint = 35 bp on 99,900 = −350 USD.
- Hold slisBNB for 30 days at 4.0 % APY (slisBNB exchange-rate accrual,
  assuming BNB stable):
  +99,550 × 4.0 % × 30/365 = **+327 USD**.
- Net strategy PnL = −350 + 327 = **−23 USD**.

Wait — the 30-day hold isn't long enough to amortise the rotation cost
at this APY spread. The rotation needs the BNB position held until the
*total* APY pickup exceeds 35 bp of cost: 35 / (1.5 / 12) = ~28 days of
*differential*. So at 30 days we're roughly breakeven; at 60 days we're
+182 USD ahead.

This is exactly the right answer — the rotation is only profitable when
the funding-flip is **persistent**. The PoC reports both the 30-day
horizon (near-zero) and a 60-day horizon (positive) to make the
sensitivity visible.

Gas: ~250k for swaps + mint. At 1 gwei × $600/BNB ≈ $0.15.

## Block pinned
**44_000_000** (early-2025) — picks a hypothetical session where Ethena
funding dipped negative for ~3 weeks (precedent: Aug 2024). PoC is
written to the offline branch by default since the trigger is an
off-chain signal.

## Addresses used
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe (`BSC.USDe`).
- `0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2` — sUSDe (`BSC.sUSDe`).
- `0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B` — slisBNB (`BSC.slisBNB`).
- `0x1adB950d8bB3dA4bE104211D5AB038628e477fE6` — Lista StakeManager
  (`BSC.LISTA_STAKE_MANAGER`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` — PCS v3 router
  (`BSC.PCS_V3_ROUTER`).
- `LOCAL_PCS_V3_SUSDE_USDT` — PCS v3 sUSDe/USDT pool. Placeholder
  `0x000000000000000000000000000000000000B544`.

## Risks
- **Rotation cost > APY pickup at short horizon**: the rotation can be
  a net loss if funding flips back positive within ~3 weeks. Mitigation:
  only rotate when the off-chain signal shows ≥ 2 weeks of negative
  funding history.
- **BNB spot move**: this strategy leaves naked BNB exposure during the
  slisBNB phase. If BNB drops 5 % over the hold, the USD-denominated
  PnL is dominated by the spot move and our 1.5 % rotation alpha is
  irrelevant. Hedge externally via perp short for delta-neutral
  variant (out of scope for on-chain PoC).
- **sUSDe cooldown queue**: emergency reversal back to sUSDe takes
  7 days of unbond if we want zero-slippage exit. PCS v3 fast exit is
  the always-available fallback.
- **slisBNB exchange-rate stagnation**: if Lista validators are slashed
  or the StakeManager pauses rewards, slisBNB APY drops too and the
  whole rotation is moot.

## Result
Status: **theoretical** (depends on Ethena funding-flip event + 30-60
day horizon). Expected PnL: **roughly breakeven at 30 days, +0.15 –
0.25 % per month thereafter** as long as the negative-funding regime
persists. PoC reports both horizons in the `pnl_usd=` block.
