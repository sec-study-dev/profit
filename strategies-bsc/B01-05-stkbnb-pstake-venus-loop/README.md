# B01-05: stkBNB (pSTAKE) → Venus → borrow BNB → pSTAKE re-stake loop

## Mechanism
Fifth-LST coverage of the B01 family. The four existing PoCs already loop
slisBNB / BNBx / ankrBNB / a multi-LST basket — **stkBNB (pSTAKE)** is the
last major non-rebasing BNB LST not yet wrapped. Same recursive shape as
B01-01 with two single-protocol legs:

1. **pSTAKE StakePool** — BNB → stkBNB at the internal `exchangeRate()`.
   Non-rebasing share token, monotonically increasing rate.
2. **Venus** — supply stkBNB as collateral, borrow native BNB against the
   stkBNB collateral factor, recycle.

## Why a 5th single-protocol LST loop is worth carving
- pSTAKE has the **lowest TVL** of the 4 main BSC BNB-LSTs, which means
  Venus' stkBNB market (when listed) carries the **highest stake / borrow
  spread** of the four — the IRM has fewer farmers driving borrow APR up.
- stkBNB on PCS often runs a small **discount** vs. its `exchangeRate`
  (illiquid LST premium), so an unwind via swap is cheaper than for
  slisBNB during stress events. The mint side is at internal rate
  (zero slippage), making the loop asymmetric in the strategy's favour.
- Carving a dedicated PoC isolates the **pSTAKE-specific peg / paused-mint
  risk** so the multi-LST basket (B01-04) doesn't have to encode it.

## Preconditions
- Block where Venus (Core *or* Venus V4 isolated pool) lists stkBNB as
  collateral. Likely an isolated pool, so `LOCAL_STKBNB_COMPTROLLER` may
  need replacement with a per-pool Unitroller.
- pSTAKE StakePool is unpaused and `stake()` / `deposit()` mint at the
  documented rate.

## Strategy steps
1. Start with 100 BNB.
2. For N=4 iterations:
   - Stake BNB → stkBNB via `IPSTAKEStakePool.stake() payable` (fallback to
     `deposit()` if the variant differs).
   - Supply stkBNB into Venus' vStkBNB.
   - Borrow BNB at `SAFETY_BPS=95%` of available liquidity.
3. Final dust stake to saturate the position.
4. Hold 30 days; accrue stake rate on stkBNB exchange rate and borrow
   interest on vBNB. Re-mark stkBNB oracle to current rate.
5. Report PnL.

## PnL math (indicative, refine at block)
- stkBNB stake APY: ~4.1 % (pSTAKE published rate, BSC validator average).
- vBNB borrow APR: ~2.2 %.
- 4 iterations at CF=0.65 × 0.95 = 0.618 → leverage ≈ 2.45×.
- Net APY ≈ 2.45 × 4.1 − 1.45 × 2.2 = **+6.86 %**.
- 30-day yield: 6.86 × 30/365 ≈ **+0.56 BNB on 100 BNB principal**.
- Gas: ~1.4M gas → ~$0.80 at 1 gwei × $600.

## Block pinned
**42_500_000**. Re-pin to a block where the stkBNB Venus market exists.

## Addresses used / TODOs
- `BSC.stkBNB` = `0xc2E9d07F66A89c44062459A47a0D2Dc038E4fb16`.
- `LOCAL_PSTAKE_STAKE_POOL` — pSTAKE BNB StakePool. **TODO verify** at
  FORK_BLOCK; placeholder is the documented pSTAKE deployer pattern.
- `LOCAL_VSTKBNB` — Venus stkBNB market token. **TODO verify** once Venus
  publishes the listing.
- `LOCAL_STKBNB_COMPTROLLER` defaults to the Core pool; replace with the
  isolated-pool Unitroller if stkBNB lives there.

## Risks
- **pSTAKE pause risk**: pSTAKE has historically paused mint during
  validator-rotation events. The loop entry would revert; not destructive.
- **Listing risk**: if Venus has not listed stkBNB, the strategy reverts
  on `enterMarkets`. Mitigation: pin a block after listing announcement.
- **stkBNB depeg**: with the lowest TVL, stkBNB has the widest depeg tail.
  Mitigation: SAFETY_BPS=95 % keeps health factor > 1.05.

## Result
Status: **theoretical** (BSC RPC pending). Expected: **+0.4–0.7 BNB per
100 BNB / 30 days**, comparable to B01-01 with the same risk shape but a
slightly fatter spread thanks to lower-utilization Venus market.
