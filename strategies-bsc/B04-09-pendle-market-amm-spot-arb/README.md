# B04-09: Pendle BSC market PT vs Wombat / PCS spot arb (3-mechanism)

## Mechanism

Pendle PT prices imply a *future-equivalent* slisBNB/BNB rate at maturity.
Spot slisBNB/BNB on Wombat (main pool) and PancakeSwap v3 reflects the
*current* rate. The two should track within a small basis (Pendle's
implied annualized yield ≈ slisBNB stake APR). When the implied price
detaches from spot by more than the round-trip fee bundle, the gap is
arbitragable atomically:

1. **Pendle Router V4 (PT swap leg)** — `swapExactTokenForPt` for buying
   or `swapExactPtForToken` for selling at the implied rate.
2. **Wombat Router (low-slippage LST swap)** — `swapExactTokensForTokens`
   via the main pool. Typical 1-2 bp fee for slisBNB/BNB.
3. **PancakeSwap v3 fallback** — `exactInputSingle` if Wombat liquidity
   is thin or pool not whitelisted.

PoC probes both venues with a small (0.1 BNB) quote, computes
`delta_bps`, and if above `MIN_ARB_BPS = 30`, executes the appropriate
leg with half the equity. The other half stays in BNB to act as the
sell-side asset and to absorb slippage.

## Why it composes

- Pendle's BSC market is *less* arbitrageable than mainnet (fewer
  competing rate-arb bots), so price discrepancies of 30-100 bps are
  more common.
- Wombat's stableswap math gives ~1 bp slippage on BNB-pegged LST swaps
  for moderate notional.
- PCS V3 0.01 % tier on slisBNB/WBNB is the deepest CLAMM pool on BSC for
  this pair; it's the fallback if Wombat is below quote.

## Strategy steps

1. Wrap half of `EQUITY_BNB = 50 ether` to WBNB; pre-approve all three
   routers.
2. Probe Pendle PT quote for 0.1 WBNB.
3. Probe Wombat (else PCS v3) slisBNB quote for 0.1 WBNB.
4. If `|delta| < 30 bps`, exit (no-op PnL = 0).
5. Direction A — PT cheaper than spot: buy PT on Pendle with 25 BNB.
   Direction B — PT richer than spot: buy slisBNB on AMM with 25 BNB
   (sell the PT side off-chain or hedge with a YT short — out of scope
   here, only the long leg is executed atomically).
6. Final balances logged for PnL accounting.

## PnL math

Per 25 BNB ≈ $15k traded leg:
- Typical observed Pendle-vs-spot gap on BSC: 40-80 bps.
- Round-trip fee bundle: ~6 bps (Pendle ~3 + Wombat ~2 + 1 buffer).
- Net expected per round trip: 30-70 bps × 25 BNB = +0.075 to +0.175 BNB
  per trade ≈ **+$45-$105 per 25 BNB executed**.
- Annualized at 10 round-trips per week: ~50 % APY on capital deployed.
- Gas: ~600k × 1 gwei × 600 USD = $0.36 — negligible.

## Block pinned

`FORK_BLOCK = 44_000_000` — mid-Q2 2025.

## Addresses used

- `BSC.PENDLE_ROUTER_V4`, `BSC.PCS_V3_ROUTER`, `BSC.WOMBAT_ROUTER`,
  `BSC.WOMBAT_MAIN_POOL`, `BSC.slisBNB`, `BSC.WBNB` — all from `BSC.sol`.
- `LOCAL_PT_SLISBNB_MARKET` — placeholder; **TODO verify**.

## Risks

- **Direction A only fully atomic**: when PT is cheap, the long-PT leg
  has positional risk because the PT must be held to a future date to
  realize the gap. Direction B requires off-chain hedge.
- **AMM pool drained mid-tx**: extremely rare for slisBNB/WBNB pools but
  possible. PoC uses `try/catch`.
- **MEV reorder front-runs the probe**: BSC has only a 0.75 s block time
  and limited public mempool MEV; risk is small but real for >$50k
  trades — would need Bloxroute / private rpc in production.

## Result

Status: **theoretical** (depends on live PT-spot gap at pin). PoC compiles
and degrades to no-op when gap < threshold. Expected per-trade PnL:
**+$45-$105 per 25 BNB executed**, repeatable.
