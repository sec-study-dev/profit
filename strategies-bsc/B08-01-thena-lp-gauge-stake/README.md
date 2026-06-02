# B08-01: Thena slisBNB/BNB LP + gauge stake → THE emission farm

## Mechanism
Plain-vanilla LP-emissions farming on Thena's ve(3,3) DEX. Three composable
moving parts:

1. **Thena volatile pair (slisBNB / WBNB)** — Solidly fork pair using x*y=k
   for non-correlated leg (slisBNB drifts away from BNB ~5% APY). `IThenaPair`
   exposes mint/burn but no minted-token bookkeeping; LP token *is* the pair
   contract itself (ERC-20).
2. **Thena Gauge** — per-pool emissions wrapper deployed by Voter. `gauge =
   IThenaVoter.gauges(pair)`. Stake the LP token via `gauge.deposit(amount)`,
   THE emissions accrue continuously, `gauge.getReward(account, [THE])`
   harvests.
3. **THE→stables conversion** — harvested THE is routed back through the
   THE/WBNB volatile pair into BNB → priced at $600/BNB.

The position has zero on-chain leverage and zero borrow — it is purely an
emissions-extraction trade. Profit = LP fees + emission value − IL.

## Why it composes
- The slisBNB/WBNB pair on Thena typically gets non-trivial THE emissions
  because both Lista and Thena have direct skin in the game (Lista pays
  bribes; Thena guides emissions). Headline gauge APR is often 30–80 % in
  THE-terms even though the underlying volume is modest.
- Because slisBNB only drifts upward against BNB (LST exchange-rate accrual),
  IL is bounded by the cumulative LST APY over the holding period — far
  tighter than a true volatile pair like BNB/CAKE.
- The gauge wrapper accepts the raw Solidly LP token (no extra wrappers, no
  zappers needed), so the position is cleanly composable with downstream
  collateral usage on Venus or Lista (separate strategy family).

## Preconditions
- Pinned block has Thena Voter live with slisBNB/WBNB volatile gauge active.
- THE/WBNB volatile pair has enough liquidity for the harvest sell-off
  without > 1 % slippage on the harvested THE batch.
- Gauge `deposit` accepts our LP token (i.e., we are not blocklisted; default
  Solidly gauges are permissionless).

## Strategy steps
1. Start with 100 BNB principal. Convert half into slisBNB via Lista
   `StakeManager.deposit` (no swap cost). Wrap the other half into WBNB.
2. Compute `pair = IThenaRouter.pairFor(slisBNB, WBNB, false)` (volatile).
   Transfer both legs to the pair, call `IThenaPair.mint(address(this))` to
   receive LP tokens. (The PoC uses `getReserves` + a tiny helper to size
   the deposit at current ratio so we don't burn dust.)
3. `gauge = IThenaVoter.gauges(pair)`. Approve LP to gauge.
4. `gauge.deposit(lpBalance)`.
5. Warp forward `HOLD_DAYS = 7` (one Thena epoch). Accrue:
   - THE emissions credited at the gauge's `rewardRate * elapsed`.
   - Pair fees credited inside the LP (compounded internally).
   - slisBNB exchange-rate drift (+slisBNB APY * elapsed) reflected by
     overriding `_priceE8[slisBNB]` against the live `convertSnBnbToBnb`.
6. `gauge.getReward(self, [THE])` → harvest THE.
7. Swap THE → WBNB on the volatile Thena pair (deduct slippage).
8. Print PnL (LP token withdrawn + WBNB + slisBNB + BNB residue) vs the
   100 BNB principal.

## Numbers (assumed at $600/BNB, $0.30/THE)
- 100 BNB ≈ $60 000 deployed → ~$30 000 each side of LP.
- Headline gauge APR (assumed): 45 % in THE.
- 7-day window: 45 % × 7 / 365 = 0.86 % of LP value in THE emissions.
- Gross emission value ≈ $60 000 × 0.86 % ≈ $518.
- Pair fees (assumed 30 bps fee tier, $1 M weekly volume, our LP is 1 %
  of TVL): $1 M × 0.30 % × 1 % ≈ $30.
- IL over 7 days (slisBNB drift +0.1 %): negligible (< $5).
- THE → BNB sell slippage at $518 batch on a ~$5 M pair: ~0.3 % = $1.55.
- Gas (5 calls × 200 k @ 1 gwei × $600/BNB ≈ $0.60).

Expected net: **~$540 / week ≈ 47 % APR LP+emissions in BNB terms.**

## Risks not modelled
- THE price has heavy beta to BSC sentiment; PoC marks at $0.30 flat.
- Gauge can be voted-down to zero emissions next epoch (re-evaluate each week).
- IL is bounded but non-zero — assumed slisBNB stays within 5 % of BNB.

## TODO
- Verify `THENA_VOTER` address; current `IThenaVoter` interface assumes the
  canonical voter is reachable via `gauges(pair)`. Some forks expose a
  separate `GaugeFactory` instead.
- Confirm THE emission rate at the pinned block from gauge `rewardPerToken`
  rather than the assumed 45 % APR.
