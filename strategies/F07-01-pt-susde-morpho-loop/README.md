# F07-01: PT-sUSDe cash-and-carry, leveraged on Morpho

## Mechanism
Pendle splits the Ethena staked-USDe receipt (sUSDe) into a Principal Token
(PT-sUSDe) and a Yield Token (YT-sUSDe). PT trades at a discount: 1 PT-sUSDe
redeems for 1 sUSDe at maturity (which itself redeems for `>$1` of USDe via
the sUSDe vault's appreciating share price), but spot PT prices in 0.92-0.96
USDC range for the 26-SEP-2024 maturity during summer 2024. That fixed
discount is the **implied APY** for the period to expiry.

Morpho Blue has a dedicated isolated market **PT-sUSDe / USDC** curated by
MEV Capital / Re7, with LLTV ~86-91.5% and a custom PendleSparkLinearDiscount
oracle that prices PT against face value linearly (i.e., it does NOT mark to
market — it always honours the redemption value at maturity, discounting
linearly to today). That oracle is critical: it lets the borrower lever
PT-sUSDe against USDC without being liquidated as the AMM spot price wiggles,
as long as the underlying sUSDe peg holds and the linear-discount path is
respected.

The composition is: buy PT-sUSDe at discount via Pendle's AMM, post as
collateral to Morpho PT-sUSDe/USDC, borrow USDC near LLTV, swap that USDC
back into more PT-sUSDe via Pendle, redeposit. Loop ~3-5 times to converge
on `~1/(1-LTV)` leverage. At maturity, redeem all PT for sUSDe (1:1), unwind
sUSDe to USDe and (if needed) sell USDe→USDC, repay the USDC debt.

## Why it composes
The composition cheats on three independent risk-decompositions:
1. **Time risk → fixed.** PT removes duration uncertainty: you know exactly
   how much USDC you receive at maturity per PT, regardless of what sUSDe's
   underlying CEX-funding APY does between now and then.
2. **Mark-to-market risk → mitigated.** The PendleSparkLinearDiscount oracle
   on Morpho prices the PT collateral on a deterministic discount schedule
   rather than the AMM spot. That decouples the loan's liquidation logic
   from short-term AMM dislocations.
3. **Liquidity risk → amortised.** USDC borrow rates on Morpho's PT-sUSDe
   markets historically sit at 6-9% utilisation-driven APR, while the
   PT-sUSDe implied yield over comparable horizons has been 15-28% APY.
   The spread × leverage is the alpha.

The strategy *only* works because Morpho explicitly underwrites PT collateral
with a non-spot oracle. On a venue that used AMM spot (Aave, Compound), a
brief widening of the PT discount would cascade liquidations and the
trade would have negative carry through realised LIQ bonuses.

## Preconditions
- Block before maturity of the target PT (e.g. before 26-SEP-2024 for the
  PT-sUSDe-26SEP2024 leg).
- PT-sUSDe/USDC Morpho market live with enough USDC supply for the loop
  size (~50M USDC supply cap on the 86% LLTV market in summer 2024).
- PT-sUSDe AMM has enough liquidity at the buy size (Pendle PT-sUSDe markets
  routinely have 30-100M USDC TVL).
- Block-time implied APY > USDC borrow APY (typically true 80% of the time).

## Strategy steps
1. Bridge USDC capital to the strategy contract (here: `_fund(USDC, 1M)`).
2. Approve Pendle Router to pull USDC.
3. Call `swapExactTokenForPt(market=PT-sUSDe-26SEP2024, ...)` with the full
   USDC balance → receive PT-sUSDe at discount.
4. Approve PT-sUSDe to Morpho. Call `supplyCollateral` to the
   PT-sUSDe/USDC market.
5. Loop N times (here N=3):
   - Read getUserAccountData equivalent on Morpho (positions + market). Compute
     borrowable USDC as `collateral_value_in_USDC * LLTV * 0.97` (3% safety).
   - `borrow(USDC)` from Morpho.
   - `swapExactTokenForPt` again to convert that USDC to more PT-sUSDe.
   - `supplyCollateral` the new PT.
6. After N rounds the position is `~K = 1/(1-L)` x PT-sUSDe collateral and
   `K-1` x USDC debt.
7. (Conceptual exit) At maturity: `redeemPyToToken` on Pendle to swap PT 1:1
   for sUSDe → unstake sUSDe → swap USDe → USDC, repay Morpho.

## PnL math
Let:
- `P_buy`  = PT-sUSDe spot price in USDC at trade time = 0.94
- `P_mat`  = PT-sUSDe redemption value in USDC at maturity ≈ 1.025 (includes
             sUSDe vault appreciation between trade time and maturity)
- `t`      = time to maturity in years = 90 / 365 ≈ 0.247
- `r_buy`  = (P_mat / P_buy - 1) / t = (1.025/0.94 - 1) / 0.247 = ~36.6% APY
             implied fixed yield (gross of fees)
- `r_borr` = USDC borrow APY on Morpho PT-sUSDe market ≈ 7.0%
- `L`      = effective LTV per loop = 0.85 (under 86.5% LLTV)
- `K`      = leverage factor = 1 / (1 - L) = 6.67

Net APY on equity:
```
net_apy = K * r_buy - (K - 1) * r_borr
        = 6.67 * 0.366 - 5.67 * 0.07
        = 2.44  - 0.397
        = 2.04   (~204% APY before fees/slippage)
```

This dwarfs the bare PT carry (36.6% APY). Realistically the achieved figure
is lower because (a) Pendle swap fees compound across loops (~0.10% per
swap, so 5 swaps ≈ 0.5% on round-trip notional, ~3% on equity), (b) Morpho
charges nonzero performance to the curator (~10% of accrued spread), and
(c) at maturity the path PT→sUSDe→USDe→USDC has nonzero slippage and a
~2-day cooldown for sUSDe unstaking. Apply a 30% haircut → realistic
**~140% APY on equity** over the holding period, i.e. ~35% absolute return
over the 90-day window.

## Block pinned
**20_200_000** (~late June 2024) — PT-sUSDe-26SEP2024 has ~90 days to
maturity, AMM liquidity is deep, Morpho PT-sUSDe/USDC market is live with
healthy USDC supply.

## Risks
- **sUSDe depeg / Ethena hedge failure.** If sUSDe's NAV falls below 1
  USDe (e.g., funding goes deeply negative or the offshore hedge takes a
  loss), the PT's *redemption value* drops and the borrow may liquidate
  even though the linear-discount oracle is smooth. Historical worst
  case for USDe vs USDC: ~-0.8% intraday.
- **Pendle AMM widening at exit.** Before maturity, exiting PT to USDC
  goes through the Pendle AMM. The implied APY can briefly spike if a
  large taker forces the AMM out of its preferred zone (5-10% impact for
  $20M trade on a $60M market). Holding to maturity eliminates this.
- **Morpho oracle / curator risk.** A vault re-allocator that withdraws
  USDC liquidity en masse during stress can push borrow APY past PT
  implied APY, killing the carry. Morpho-Blue is permissionless markets
  but the *curator* controls the supply side.
- **Smart-contract risk.** Pendle V4, Morpho Blue, Ethena, Lido-style
  systems are all attack surface.
- **Gas / cooldown.** sUSDe has a 7-day vault cooldown for direct
  unstaking; the unwind path either eats the cooldown or sells sUSDe on
  Curve at a discount.

## Result
Status: theoretical (forge not installed; market id derived from oracle
+ IRM constants at fork block; verify against MarketCreated events on the
fork before live deployment). The PoC walks through the buy → supply →
borrow → buy cycle once with explicit ApproxParams set by off-chain
estimation, and reports balance deltas plus the standing Morpho position.
Expected PnL: **+25% to +40%** absolute over the 90-day window on $1M
equity at K≈6 (Pendle fees + sUSDe NAV growth + USDC borrow cost included).
