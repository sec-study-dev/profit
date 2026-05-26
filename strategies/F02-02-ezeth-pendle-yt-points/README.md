# F02-02: ezETH points farming via Pendle YT (point-decoupling loop)

## Mechanism
Renzo's ezETH is a non-rebasing LRT minted by `RestakeManager.depositETH()` against
restaked ETH delegated to EigenLayer operators. ezETH earns:
- Underlying ETH staking yield (~3%)
- EigenLayer restaking points
- Renzo's own **ezPoints** (Season 1+, redeemable for REZ airdrop)

Pendle wraps ezETH into an SY (`SY-ezETH`), then splits it into **PT-ezETH**
(fixed yield zero-coupon) and **YT-ezETH** (variable yield + ALL points / rewards
attributable to the underlying ezETH for the remaining time to maturity).

**The key Pendle property:** holding 1 YT-ezETH entitles the holder to the
**same** points stream as holding 1 ezETH directly, until maturity, but at a
fraction of the dollar cost (often 1–5% of the underlying ezETH price). YT decays
to zero at expiry.

## Why it composes
A YT-ezETH purchase is a **leveraged point exposure with bounded downside**:

```
points_per_$  ≈  underlying_point_emission / YT_price
              ≈  (full ezETH point rate) / (~3% of ezETH price)
              =  ~33x point efficiency vs. holding ezETH spot
```

Composition with money-market loop:
1. Use cash collateral (USDC or WETH) at a Morpho/Euler vault to borrow more cash.
2. Use borrowed cash to buy more YT-ezETH.
3. Repeat. Net result: a leveraged YT stack, capped by YT's volatility (margin
   requirements bite if implied APY moves).

Versus F02-01 (direct weETH loop): YT-ezETH delivers ~30× more points per dollar
of capital deployed, but **costs the full YT premium as time-decay** every block.
If points convert to airdrop $ > YT time-decay → strict win.

## Preconditions
- Block: 19,400,000 (early March 2024 — after Pendle ezETH market launched and
  ezPoints S2 active; ezETH momentum, YT trading 4-7% APR implied points-value)
- Pendle Router V4 deployed
- Pendle ezETH market with expiry 25-Apr-2024 active (~50 days TTM at FORK_BLOCK).
  Note: the 27-Jun-2024 PT/YT ezETH pair only exists on Arbitrum; on Ethereum
  mainnet the closest live maturity in early Mar 2024 is **25-Apr-2024**.
- Renzo `RestakeManager` accepts ETH deposits (Phase-2 caps lifted)

## Strategy steps
1. Receive 100 WETH equity.
2. Unwrap to ETH; mint ezETH via `RestakeManager.depositETH{value: x}()`.
   (Or: directly buy YT-ezETH with WETH via Pendle Router — Pendle handles SY-mint.)
3. `IPendleRouter.swapExactTokenForYt(WETH, ezETHMarket, ...)` with 100 WETH input
   → receive ~3,000 YT-ezETH (at YT/SY price ratio ≈ 0.033 = 3.3%).
4. Hold YT-ezETH until accrued points materialise (ezPoints S2 + EL pts).
5. At maturity (or earlier if implied-APY pops), `swapExactYtForToken()` back to
   WETH. The cash leg is **lossy** by design (YT decays); the value is the
   off-chain points-airdrop claim.

## PnL math
Inputs: 100 WETH equity ($300k at $3000). YT/SY price ratio ≈ 0.033.

```
YT purchased   = 100 / 0.033 = ~3,030 YT-ezETH
Cash on YT     = 100 WETH ($300k)

Cash leg (over 120-day TTM):
  YT decay = 100% of YT cost over TTM = -$300,000 (worst case, no rebalance)
  Variable yield captured = 3% APR × 120/365 × 3,030 × $3000 = ~$90,000
  Cash PnL ≈ -$210,000

Point leg (the entire thesis):
  ezPoints earned ≈ 3,030 × (1 pts/ezETH/hour boost) × 24 × 120 = ~8.7M ezPoints
  At implied REZ airdrop value $0.10/pt (mid-bull case) → $870,000
  At conservative $0.02/pt → $174,000

  EigenLayer pts ≈ 3,030 × (1 ETH-day) × 120 = ~363,600 ETH-days
  At $2/ETH-day (S1 conversion ratio applied) → $727,000
  Conservative $0.5/ETH-day → $182,000
```

Combined estimate over 120 days:
- Conservative: -$210k + $356k = **+$146k** (≈ +49% on equity)
- Bull: -$210k + $1.6M = **+$1.4M** (≈ +470%)
- Bear (points worthless or rate cut): -$210k + $90k = **-$120k** (≈ -40%)

## Block pinned
- Fork block 19,400,000 (early March 2024)
- Reference: Pendle ezETH-25APR2024 market PT/YT/SY contracts active at this block.
- ezETH-25APR2024 market (LP) address: `0xD8F12bCDE578c653014F27379a6114F67F0e445f`
- PT-ezETH-25APR2024: `0xeEE8aED1957ca1545a0508AFB51b53cCA7e3C0d1`
  (https://etherscan.io/token/0xeee8aed1957ca1545a0508afb51b53cca7e3c0d1)
- YT-ezETH-25APR2024: `0x256Fb830945141f7927785c06b65dAbc3744213c`
  (https://etherscan.io/token/0x256fb830945141f7927785c06b65dabc3744213c)
- SY-ezETH: `0x22E12A50e3ca49FB183074235cB1db84Fe4C716D`
  (https://etherscan.io/token/0x22e12a50e3ca49fb183074235cb1db84fe4c716d)
- The original 27-JUN-2024 PT/YT/market only exists on Arbitrum
  (PT @ `0x8ea5040d423410f1fdc363379af88e1db5ea1c34` on Arbiscan); the 27JUN24 token
  formerly listed here was actually YT-weETH-27JUN24 (`0xfb35Fd00...`), a
  different LRT.

## Risks
- **Points dilution.** Renzo can change emission rate (and has — S1 → S2 cut).
- **Implied APY divergence.** YT prices in points/yield expectations; a market
  consensus shift can wipe out the YT value pre-maturity.
- **ezETH depeg.** Happened Apr-2024 around the REZ airdrop snapshot; ezETH
  spot traded -2-3% below ETH. YT NAV unaffected long-term but mark-to-market dings.
- **Pendle smart-contract risk.** YT redemption requires Pendle market liquidity.
- **Sybil dilution.** Renzo's airdrop formula applied caps and Sybil filters;
  points-per-$ conversion may not be linear at scale.

## Result
Status: **theoretical**. Cash-leg execution is straightforward and reproducible;
the entire PnL is dominated by the unknown points-to-$ conversion.

PnL range (120-day, $300k notional):
- Bear (points → 0): **-$120k** to **-$210k** (locked-in time decay)
- Base case (historical REZ + EIGEN realised values): **+$140k to +$400k**
- Bull (top-of-cycle airdrop FDV): **+$1M+**
