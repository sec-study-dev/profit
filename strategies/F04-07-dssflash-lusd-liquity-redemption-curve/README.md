# F04-07: DssFlash + LUSD-Curve + Liquity redemption — cross-CDP atomic arb

## Mechanism

Three-mechanism atomic loop pinned under the F04 family because the *entry
leg* is a Maker DAI flashmint:

1. **DssFlash** (`0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA`) — Maker's
   ERC-3156 DAI flash mint. Zero-fee, callable from any contract, capped by
   the `line()` parameter (typically 500 M DAI in 2023+).
2. **Curve LUSD/3pool meta-pool** (`0xEd279fDD11ca84bEef15AF5D39BB4d4bEE23F0cA`)
   — The deepest LUSD/stable venue; LUSD trades at intermittent discounts
   below par because Liquity v1 has no peg-keeper and the only par-bound is
   the 0.5% redemption fee floor.
3. **Liquity v1 TroveManager.redeemCollateral**
   (`0xA39739EF8b0231DbFA0DcdA07d7e29faAbCf4bb2`) — Burns LUSD, pays out ETH
   at the oracle price net of the dynamic `redemptionRate`. This is the *only*
   on-chain par-anchor LUSD has: anyone with LUSD can redeem 1 LUSD for
   $1-r worth of ETH.

The whole point: when LUSD trades at $0.985 on Curve and the redemption fee
is 0.5%, you can burn $1 of DAI -> ~1.0152 LUSD -> 1.01 worth of ETH -> swap
back to DAI for ~$1.008 net. That's ~80 bps of zero-capital atomic edge.
Maker's free flashmint supplies the working capital.

This is "cross-CDP" because the trade *physically transfers debt from Liquity
to nowhere*: it shrinks the Liquity LUSD supply and rebalances Curve's
LUSD/3pool ratio without ever opening or touching a Maker Vault.

## Why it composes

Only this stack works:
- **DssFlash** is the only zero-fee DAI flash mint at scale (Aave charges
  0.05%, Balancer is also zero-fee but flash-paths through the Vault add
  bookkeeping).
- **Liquity v1 redemption** is the only fully-atomic LUSD->ETH peg-anchor.
  GHO has no redemption, crvUSD has flap auctions (not atomic), USDS has the
  PSM-backed wrapper but no public redemption-against-vault.
- **Curve LUSD/3pool** carries the LUSD spot price; the meta-pool's
  underlying coin path means a single `exchange_underlying` hop covers
  DAI->LUSD without touching 3CRV explicitly.

## Preconditions

1. `Curve.get_dy_underlying(DAI, LUSD, 1e18) * (1e18 - redemptionRate) > 1e18 + edge_floor`.
   PoC pre-quotes this before flashminting. `edge_floor = 0.4% + 0.2%`
   (slippage budget on the ETH->USDT->DAI return leg).
2. Liquity v1 not in recovery mode and post-bootstrap (more than 14d since
   deployment — long since true).
3. `redemptionRate <= 2.5%`. Liquity caps fees at 5%, but at >2.5% the trade
   no longer clears.

## Strategy steps

All in one tx, no warp:

1. Pin to `16_818_900` (SVB-weekend; LUSD trading ~$0.97 on Curve, redemption
   fee at ~0.5% floor).
2. Read `get_dy_underlying` and `getRedemptionRateWithDecay`. Bail without
   minting if `grossE18 <= 1e18 + edge_floor + 2 bps`.
3. `DssFlash.flashLoan(this, DAI, 2_000_000e18)`.
4. In callback:
   - `Curve.exchange_underlying(DAI->LUSD, amount, 0)` -> `lusdOut`.
   - `TroveManager.redeemCollateral(lusdOut, 0, 0, 0, 0, 0, MAX_FEE=2.5%)` ->
     ETH on the contract.
   - WETH wrap, `tricrypto2 WETH->USDT`, `3pool USDT->DAI`.
   - Repay `amount + 0` to DssFlash.
5. Residual DAI on contract == realised profit.

## PnL math

```
gross_per_DAI = lusdPerDai * (1 - r_liquity)
edge_per_DAI = gross_per_DAI - 1 - tricrypto_slip - 3pool_slip
profit_DAI   = FLASH_DAI * edge_per_DAI
```

At pinned block (LUSD ~$0.97, r ~0.5%):
```
lusdPerDai ≈ 1.030
gross = 1.030 * 0.995 = 1.0248
edge = 0.0248 - 0.0015 - 0.0005 = 0.0228 -> 228 bps
profit = 2_000_000 * 0.0228 = $45_600
```

Gas: 1.4M for the full callback chain. At 20 gwei / ETH=$1550 (SVB era):
~$43. Net ≈ $45_550.

The slimmer regime (LUSD = $0.99, r = 0.8%) collapses the edge to ~2-3 bps —
the discovery branch gates entry, so a low-edge block is a no-op test pass.

## Block pinned

`16_818_900` — March 11 2023, SVB weekend. LUSD on Curve sold off to ~$0.97
because USDC depegged through the 3CRV underlying. Liquity redemption fee
sat at the 0.5% floor.

## Risks

- **LUSD depeg propagation reverses mid-tx.** A simultaneous Curve buy from a
  competing searcher could close the spread before our redemption clears.
  Atomic execution mitigates: if the post-buy Curve state already lifted the
  price, we still own LUSD and can redeem at 1:1 with Liquity.
- **Liquity recovery mode.** When TCR < 150% the redemption mechanic changes
  (PCR-dependent). PoC catches the revert and continues — but then has no
  ETH to swap back, so the flash mint repay underflows and the whole tx
  reverts. Acceptable: nothing happens on-chain.
- **`maxIterations = 0`** walks the entire SortedTroves list. On 2025+
  blocks this can hit the block gas limit. PoC uses zero hints which is fine
  for the pinned 2023 fork; production version should compute hints
  off-chain via `HintHelpers`.
- **Curve tricrypto2 deprecation.** A future ETH/USDT venue rotation would
  require routing through a v3 pool. Address kept inline-local in case the
  family bumps Mainnet.sol.

## Result
Status: theoretical-historical-replay
Expected PnL: ~228 bps × notional on 2M DAI per event (~$45,550 net at SVB-weekend LUSD ~$0.97 + 0.5% redemption fee; ~$22k at wider slippage scenario)

A canonical zero-capital cross-CDP arbitrage anchored on Maker's free
flashmint. PoC asserts that when the discovery branch passes, the tx returns
strictly positive DAI; otherwise it no-ops. Expected profit at the pinned
block: ~$45k on a 2M flash, ~$22k after a wider slippage scenario.
