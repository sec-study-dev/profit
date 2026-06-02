# B05-05: PT-sUSDe (Pendle) + Lista lending + USDe — 3-mechanism carry

## Mechanism (3-mech)
Three BSC primitives stacked into one position:

1. **Pendle PT-sUSDe** — buy the principal token at a fixed YTM discount
   (~11% annualised). Locks the *collateral leg* into a fixed-yield
   instrument and removes the variance of Ethena's perp funding from the
   collateral side.
2. **Lista Lending V2** — accepts PT-stable collateral on its isolated
   markets (assumed live at the pinned block — // TODO verify the PT-sUSDe
   market on Lista is open). Borrow lisUSD at ~4% APR. LTV is 0.72 (more
   conservative than the 0.82 used for spot sUSDe in B05-03 because PT
   carries pre-maturity price volatility).
3. **Ethena sUSDe (recycled leg)** — the borrowed lisUSD is swapped to
   USDe on the PCS StableSwap lisUSD/USDe pool, then deposited into sUSDe
   so the recycled portion still earns the floating Ethena APY (~9%).

This is genuinely 3-mechanism: Pendle for the *fixed* carry on principal,
Lista for the *leverage*, Ethena sUSDe for the *floating* carry on
recycled debt. Unlike B05-03 (which uses spot sUSDe everywhere), here
the collateral and recycled legs accrue from different rate sources, so
the position is partially insulated if Ethena APY collapses.

## Why it composes
- The PT discount and the sUSDe APY are mechanically linked (PT YTM ≈
  expected sUSDe APY × time-to-maturity factor), but at any given point
  PT trades richer or cheaper than fair value because Pendle AMM
  liquidity is thin on BSC. When PT is cheap, the principal leg earns
  more than holding sUSDe directly; the recycled leg picks up the
  floating sUSDe rate as well — best of both worlds.
- The strategy is robust to Ethena funding flips (the principal leg is
  locked at fixed YTM) and robust to lisUSD borrow rate spikes (only the
  recycled portion is debt-financed).
- Lista's PT-collateral market is the keystone — without it the trade
  reduces to either pure PT-cash-and-carry (B04-01) or pure sUSDe-loop
  (B05-03). The combination is novel.

## Preconditions
- BSC block where (a) Pendle PT-sUSDe market is live and not yet matured,
  (b) Lista Lending V2 has listed a PT-sUSDe isolated market, (c) PCS
  StableSwap has a lisUSD/USDe pool with > $1M liquidity.
- PT entry slippage < 30 bp at the principal notional ($100k).

## Strategy steps
Principal: 100,000 USDe (≈ $99,900 at $0.999).

1. Acquire PT-sUSDe via `IPendleRouter.swapExactTokenForPt(USDe → PT)`
   at ~25 bp slippage. Now holding ~99,750 PT.
2. Loop 3x:
   - Supply PT to Lista Lending isolated PT-sUSDe market.
   - Borrow `0.72 × 0.95 = 0.684` of collateral USD as lisUSD.
   - Swap lisUSD → USDe on PCS StableSwap (5 bp).
   - Deposit USDe → sUSDe (no slippage; ERC-4626).
3. Hold 60 days, then unwind by repaying lisUSD and either:
   (a) holding PT to maturity for the full YTM, or
   (b) selling PT back into USDe via Pendle (if pre-maturity exit).

## PnL math (closed-form, 60 days)
- Leverage factor L (with N=3 loops, per-step LTV 0.684):
  L = 1 + 0.684 + 0.468 + 0.320 + 0.219 ≈ 2.69
- Debt leverage D = L − 1 ≈ 1.69
- PT yield on principal: 1.0 × 11% = 11%
- Recycled sUSDe yield on D: 1.69 × 9% = 15.21%
- lisUSD borrow cost on D: 1.69 × 4% = 6.76%
- Swap drag: 20 bp × 3 loops × 1.69 = 101 bp
- Amortised PT entry drag: 25 bp × (365/60) = 152 bp
- Net APY: 11 + 15.21 − 6.76 − 1.01 − 1.52 = **16.92% annualised**
- 60-day PnL on $100k principal: 100,000 × 16.92% × 60/365 ≈ **+2,781 USD**

Gas: ~600k for setup + 3 loops. At 1 gwei × $600/BNB ≈ $0.36.

## Block pinned
**42_900_000** — mid-Q1 2025 window when Pendle BSC has live PT-sUSDe
markets and Ethena sUSDe APY > 8%.

## Addresses used
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe (`BSC.USDe`).
- `0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2` — sUSDe (`BSC.sUSDe`).
- `0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5` — lisUSD (`BSC.lisUSD`).
- `BSC.LISTA_LENDING` — Lista Lending V2.
- `BSC.PENDLE_ROUTER_V4` — Pendle Router V4 (BSC).
- `LOCAL_PT_SUSDE_MARKET` — `0x9eC4c502D989F04FfA9312C9D6E3F872EC91A0F9`
  (placeholder; verify via Pendle BSC SDK).
- `LOCAL_PCS_STABLE_LISUSD_USDE` — `0x…B533` (placeholder).

## Risks
- **PT pre-maturity price risk**: if interest rates spike, PT-sUSDe
  marks down, triggering Lista liquidation despite the 0.72 LTV.
  Mitigation: cap N_LOOPS at 3 and run with SAFETY_BPS = 95%.
- **Pendle BSC liquidity**: thin compared to mainnet. Entry slippage
  can exceed 25 bp on $100k. Mitigation: scale principal down or split
  the entry across multiple blocks.
- **Lista PT-collateral market not live**: this is a frontier
  assumption. If the market does not exist at pinned block, the PoC
  degrades to the offline projection.
- **Ethena APY collapse during hold**: only affects the recycled leg
  (D ≈ 1.69 of principal), not the PT leg. Floor PnL is the PT YTM
  minus borrow cost minus drags ≈ +5-6% annualised.

## Result
Status: **theoretical, depends on Lista PT-collateral market listing**.
Expected PnL: **+2,500–3,000 USD on $100k over 60 days** (~17% APY
gross). PoC reports the offline projection by default and runs the
forked legs when both Pendle and Lista markets are live at the pinned
block.
