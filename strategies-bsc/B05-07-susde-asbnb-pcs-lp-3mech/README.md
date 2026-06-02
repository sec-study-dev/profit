# B05-07: sUSDe + Astherus asBNB + PCS LP — 3-mechanism triangular yield

## Mechanism (3-mech, parallel)
Allocate the principal across three independent yield streams that ride
uncorrelated macros:

1. **Ethena sUSDe (50% allocation)** — staked USDe earns the Ethena
   perp-funding APY (~9%). Backed by Ethena's delta-neutral basis trade
   on Binance/Bybit/OKX perps.
2. **Astherus asBNB (35% allocation)** — restaked BNB (Astherus +
   Babylon stack) earns BSC validator inflation + restaking points
   (~5.5% BNB-denominated). Note: this leg has BNB spot exposure.
3. **PCS v3 sUSDe/USDT LP (15% allocation)** — concentrated LP on the
   stable-stable 5bp pool, harvesting fee income (~12% APR when ranged
   tightly around peg). Stable-stable pair means IL is dominated by
   small operational drift (~2 bp/month modelled).

## Why it composes
- The three yield streams are **driven by independent macros**: Ethena
  funding (perps market), BSC validator inflation (POS economics), PCS
  LP fees (DEX volume). When sUSDe APY collapses on a funding flip,
  asBNB and LP fees continue earning. When BSC validator rewards drop,
  Ethena and LP carry the book. When DEX volume dies, the other two
  legs carry.
- The 50/35/15 split is designed so the sUSDe leg dominates the carry
  in the "normal" regime, while the asBNB and LP legs provide a hedge
  against Ethena-specific risk (Ethena counterparty, USDe peg event).
- Triangular basket: not a leveraged loop. The principal stays unlevered.
  This makes B05-07 the "boring buy-and-hold" sibling of B05-01/05/06.
  Drawdown risk is dominated by the BNB spot move on the asBNB leg.

## Preconditions
- BSC block where Astherus StakeManager accepts BNB deposits.
- PCS v3 sUSDe/USDT 5bp pool exists with > $500k liquidity.
- USDe / USDT spot trades within 30 bp of peg (otherwise the entry
  swap on the asBNB leg eats too much).

## Strategy steps
Principal: 100,000 USDe (≈ $99,900 at $0.999).

1. Allocate $49,950 USDe → sUSDe via `ISUSDe.deposit`. Zero slippage.
2. Allocate $34,965 USDe → USDT (1 bp PCS) → WBNB (5 bp PCS) → BNB →
   `ASTHERUS_STAKE_MANAGER.deposit{value: bnb}()` → asBNB. Entry drag
   ~10 bp.
3. Allocate $14,985 USDe → mint NFPM position on PCS v3 sUSDe/USDT 5bp
   centered around current tick with ±20 bp band. Entry drag ~5 bp.
4. Hold 30 days. Carry accrues:
   - sUSDe: $49,950 × 9% × 30/365 = **+$369**
   - asBNB: $34,965 × 5.5% × 30/365 − 10 bp entry = $158 − $35 = **+$123**
   - LP: $14,985 × 12% × 30/365 − 5 bp entry − 2 bp IL = $148 − $7 − $3 = **+$138**
   - **Total: +$630 over 30 days ≈ 7.7% annualised on principal.**

5. Unwind: redeem sUSDe via cooldown (or fast PCS exit), unstake asBNB
   (Astherus has a withdraw queue — model as 7-day delay), remove LP.

## PnL math (closed-form, 30-day)
- sUSDe leg: $49,950 × 9% × 30/365 = **+$369**
- asBNB leg: $34,965 × (5.5% × 30/365) − $35 entry = **+$123**
- LP leg: $14,985 × (12% × 30/365 − 5 bp − 2 bp) = **+$138**
- **Net: +$630 / 30 days = 7.55% annualised.**

Gas: ~600k for setup (4 swaps + 2 deposits + 1 NFPM mint). At 1 gwei ×
$600/BNB ≈ $0.36.

## Block pinned
**43_100_000** — Q1 2025, normal-regime Ethena funding (~9% APY),
asBNB markets live, PCS v3 stable LP active.

## Addresses used
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe (`BSC.USDe`).
- `0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2` — sUSDe (`BSC.sUSDe`).
- `0x77734e70b6E88b4d82fE632a168EDf6e700912b6` — asBNB (`BSC.asBNB`).
- `0xb0fd0bF41fbdD5C56DB8FFA2AD5D9F0B27c2b0A1` — Astherus StakeManager
  (`BSC.ASTHERUS_STAKE_MANAGER`).
- `BSC.PCS_V3_ROUTER`, `BSC.USDT`, `BSC.WBNB`.
- `LOCAL_PCS_V3_SUSDE_USDT_5BP` — `0x…B571` (placeholder).

## Risks
- **BNB spot move dominates the asBNB leg PnL**: a 5% BNB drop over the
  hold inflicts ~$1,750 spot loss on the $35k leg, dwarfing the $123
  carry. Mitigation: pair the asBNB leg with a short BNB perp on
  Binance Futures (off-chain hedge). Out of scope for the on-chain PoC.
- **LP IL on de-peg event**: if USDe or USDT depegs by ≥ 50 bp, the LP
  range gets exhausted and the position holds 100% of the cheap side.
  Mitigation: monitor and re-range; cap LP allocation at 15%.
- **Astherus withdraw queue**: emergency exit needs 7 days unless we
  swap asBNB on a secondary venue (likely thin liquidity). Mitigation:
  small allocation + accept the queue.
- **Ethena counterparty / depeg**: shared with B05-01..04. Mitigation:
  50% cap on the sUSDe leg.

## Result
Status: **theoretical, low-leverage carry**. Expected PnL: **+$630 /
$100k / 30 days ≈ 7.55% annualised**, with three uncorrelated yield
sources and an explicit hedge thesis vs Ethena-specific tail risk. PoC
runs the offline projection by default and exercises the sUSDe + USDe
→ WBNB legs on the forked branch.
