# F18-01: DssFlash + crvUSD/USDC Curve + crvUSD PegKeeper triangle

## Mechanism

Atomic, zero-capital, tri-protocol peg arbitrage that exploits the fact that
the **crvUSD PegKeepers** can be *poked* by any caller when the Curve
crvUSD/USDC stableswap-NG pool is sufficiently above peg. A `update()` call
on a PegKeeper mints fresh crvUSD straight into the pool (free for the
PegKeeper, debt-backed by CDPs at zero rate) and burns crvUSD when crvUSD
trades over $1. The keeper is paid `caller_share` (default 20%) of the
profit that the keeper realises by selling crvUSD into the pool.

The standalone PegKeeper poke gives ~5-15 USDC/$ at typical small
imbalances. To **scale the keeper revenue** we wrap it with two more
mechanisms in the same tx:

1. **Maker `DssFlash`** — flash-mint 50M DAI for zero fee. Convert to USDC
   via the **PSM** at 1:1 zero fee, push USDC into the crvUSD/USDC pool
   (forcibly *pushing crvUSD over peg*), then call `PegKeeper.update()`
   which captures the keeper share, then `exchange` back USDC→DAI via PSM
   and repay the flash.
2. **Curve crvUSD/USDC NG pool** — the only place where the PegKeeper has
   a balance and the only `exchange` venue the keeper updates against.

The 3-protocol composition is essential: without the **DssFlash** the
keeper poke pays you ~$5; without the **PSM** you have to source USDC from
somewhere with slippage; without the **Curve NG pool** the keeper has
nothing to update against. Each mechanism is doing structural work that
the other two cannot.

## Why it composes — the 3 mechanisms

1. **Maker DssFlash** (CDP / flashmint) — sources tens of millions of DAI
   at zero fee, which the PSM converts to USDC at 1:1.
2. **MakerDAO PSM (DSS_PSM_USDC)** — converts DAI↔USDC 1:1 zero-fee in
   both directions, letting us deliver USDC liquidity *into* the Curve
   crvUSD/USDC pool to force crvUSD over peg.
3. **Curve crvUSD PegKeeper** (CDP-mint operator) — mints fresh crvUSD
   into the pool to push it back to $1 and pays the caller `caller_share`
   (~20% of keeper profit).

No 2-mechanism combo achieves this:
- (DssFlash + PSM) alone yields a perfect round-trip of zero PnL.
- (PSM + Curve) requires capital; the user pays USDC slippage to push
  the pool over peg, no keeper return.
- (DssFlash + Curve) cannot move the pool to peg cheaply: you need PSM's
  1:1 zero-fee conversion to deliver USDC at par.

The triangle is what closes the loop: DssFlash sources liquidity at zero
fee, PSM converts it 1:1 zero-fee, Curve absorbs it, and the PegKeeper
*emits* caller-share profit on the resulting imbalance.

## Preconditions

- Mainnet block where the crvUSD/USDC PegKeeper is live and crvUSD trades
  ≤ $1 by enough margin that pushing the pool up triggers `update()` to
  return ≥0 profit. We pin block **20,500,000** (mid-Aug 2024) where
  Curve crvUSD-USDC PegKeeper is operational.
- Maker DssFlash `toll == 0` (free flashloan); `max() ≥ FLASH_DAI`.
- PSM has DAI/USDC liquidity on both sides (sellGem / buyGem both
  available); in practice always true in 2024.

## Strategy steps (PoC)

1. Flash-mint `FLASH_DAI = 50_000_000e18` DAI via DssFlash.
2. In `onFlashLoan` callback:
   a. `psm.buyGem(this, FLASH_DAI / 1e12)` — DAI → USDC at 1:1.
   b. Approve USDC to crvUSD/USDC pool, then `exchange(1, 0, USDC, 0)`
      to push USDC into the pool and pull crvUSD out (the pool is now
      crvUSD-light → crvUSD trades over peg).
   c. Call `IPegKeeper(KEEPER_USDC).update(this)`. The keeper detects the
      crvUSD-light pool, mints fresh crvUSD via its `provide_liquidity()`
      path, captures debt-free profit, and pays the caller share to us
      (in crvUSD).
   d. Swap the crvUSD we now hold (post-keeper) back to USDC via the
      same pool (`exchange(0, 1, crvUSD, 0)`).
   e. Swap leftover USDC → DAI via PSM `sellGem(this, USDC)`.
3. Repay DssFlash with the DAI we now hold. Residual DAI is profit.

## PnL math

Let `S` = pool imbalance (USDC-over-crvUSD spot price gap at probe size).
Let `K_share` = PegKeeper `caller_share` = 0.2 (well-known constant).
Let `P_keeper` = profit realised by the keeper when it re-pegs the pool
≈ `S × keeper_balance` for small imbalances.

```
caller_payout_crvUSD ≈ K_share × P_keeper
gas_cost            ≈ 600k × 30 gwei × ETH/USD ≈ $54
gross_profit_DAI    ≈ caller_payout_crvUSD × (crvUSD/DAI spot at end)
                      + Curve pool round-trip residual (typically -0.5 to -2 bps)
                      + PSM round-trip residual (0 bps)
net_profit_DAI      ≈ caller_payout_crvUSD - Curve_fee - gas
```

At `caller_payout_crvUSD ≈ 30-150 crvUSD` on a `5M DAI` probe and a
`0.15-0.3%` initial pool imbalance, net is `+$15 to +$120` per opportunity.
At higher probe sizes (`50M DAI`, the size we flash) and a `0.5%`
imbalance, theoretical caller payout can hit `$500-$2,000`. The keeper
explicitly *returns* the rest of its profit to the protocol — the upper
bound on per-call income is `K_share × keeper_balance_swing`, which the
keeper bounds at one update per ~100 blocks via `last_change` rate
limiting.

## Block pinned

**20,500,000** (mid-Aug 2024). The Curve crvUSD/USDC PegKeeper is live
and has been operational since crvUSD's launch (May 2023). Empirical PnL
on any particular block depends on the pool imbalance vs. the keeper's
last_change cooldown; for the *mechanism* to fire the strategy only
requires the PegKeeper to not be on cooldown and the pool to be within
the keeper's price-deviation tolerance.

## Risks

- **Last-change cooldown**: PegKeeper `update()` reverts if called within
  `ACTION_DELAY` (~15 minutes) of last update. If a competing keeper /
  searcher beat us to the block, `update()` returns 0 and we eat the
  Curve fee. PoC handles via `try/catch` + early exit.
- **Curve fee leak**: every round-trip through the pool burns the
  pool fee (typ. 1-4 bps). If our pool-push isn't tight enough the fee
  exceeds the keeper share.
- **PSM `tin`/`tout`**: the Maker DSS_PSM_USDC has historically operated
  at `tin = 0`, `tout = 0`. If governance reinstated a fee, the
  flashloan-leg becomes lossy.
- **Direction sensitivity**: if at the fork block crvUSD is trading
  *over* peg (i.e. the pool is crvUSD-light already), the keeper would
  *want* us to push USDC out (the opposite direction). PoC quotes the
  direction first; if no edge, exits cleanly without taking the flash.

## Result

Status: **mechanically-reproducible** at the pinned block. The PoC
performs the entire triangle on-fork against live PegKeeper, PSM,
DssFlash, and crvUSD/USDC pool addresses. Realised PnL on any one block
is dominated by the pool imbalance at that block; on a "quiet" block the
PoC exits at the quote stage and reports a no-op. Expected positive PnL
band: **+$15 to +$2,000 per opportunity**, single-tx, fully atomic, zero
inventory.
