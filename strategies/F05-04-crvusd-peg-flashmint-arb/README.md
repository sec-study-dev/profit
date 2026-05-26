# F05-04: crvUSD peg arbitrage via Maker DSS-Flash + Curve

## Mechanism
crvUSD's peg is maintained jointly by:
1. The wstETH/WBTC/sfrxETH/WETH Controller borrow rates (PID-controlled to
   target $1).
2. **The "PegKeeper" pools**: pre-deposited crvUSD inventory in Curve
   stableswap-NG pools `crvUSD/USDC`, `crvUSD/USDT`, `crvUSD/PYUSD`,
   `crvUSD/TUSD`. The four PegKeepers (one per pool) `provide()` crvUSD into
   a pool whenever crvUSD trades > $1.001 there, and `withdraw()` crvUSD
   from a pool when it trades < $0.999. That move is permissionless.

This creates a *forced* on-chain peg defense around the four Curve pools but
**not** around any *external* venue. If crvUSD trades above peg on Uni v3
(`USDC/crvUSD 0.05%` pool, or `crvUSD/PYUSD 0.05%`) the four PegKeepers do
not act until the price moves back via the Curve pools. The peg-arb thesis:
**when crvUSD > $1 anywhere, mint fresh crvUSD via a Maker DAI flash mint +
Curve route, sell it at the premium, repay DAI; pocket the spread**.

Verified flash-source / PSM:
- DssFlash (DAI ERC-3156 flash mint): `0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA`
- DSS PSM USDC<->DAI: `0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A`

The "mint crvUSD" path doesn't actually go through the Controller (that
would require collateral); instead the arber buys crvUSD from a Curve pool
that holds plenty of inventory (typically the `crvUSD/USDC` pool whose
PegKeeper deposits 5-30% of pool TVL). If the pool quotes are close to peg
but Uni v3 trades premium, you arb the Curve quote -> Uni v3 sell.

## Why it composes
1. **Maker DssFlash** mints up to 500M DAI at 0% fee. This gives a flat
   stable-side capital base with zero cost.
2. **DSS PSM USDC** converts DAI <-> USDC 1:1 with `tin/tout` fees (long-time
   at 0/0 bps; verify at fork block).
3. **Curve `crvUSD/USDC`** pool absorbs USDC at peg-target slippage.
4. **Uni v3 crvUSD/PYUSD or crvUSD/USDC** is the *external* venue where the
   premium lives.

The four-protocol composition is required because:
- Maker provides zero-fee, infinite-scale dollar capital.
- DSS PSM gives the USDC liquidity bridge.
- Curve PegKeepers fix the *Curve-pool* peg, leaving room outside.
- Uni v3 is where the premium actually trades.

Critically, **Maker DSS-Flash has no token-level recipient restriction**, so
the arber can intermediate without holding any DAI before/after the trade.

## Preconditions
- crvUSD price on Uni v3 above peg (≥ $1.005) while Curve PegKeeper pools
  hold inventory. Empirically common in late 2023 (Sep-Nov) when borrow
  demand was strong; sporadically in Apr-May 2024.
- DssFlash `max()` > 50M DAI (always true on mainnet).
- PSM `tin = tout = 0`. Set since 2023; verify at fork block.

## Strategy steps
1. `DssFlash.flashLoan(this, DAI, 50_000_000e18, data)`.
2. Inside `onFlashLoan`:
   a. `PSM.buyGem(this, usdcAmt)` to swap DAI -> USDC (50M USDC = 50M DAI
      at 0 fee). USDC has 6 decimals so `usdcAmt = daiAmt / 1e12`.
   b. USDC -> crvUSD on Curve `crvUSD/USDC` pool (idx 1 -> 0).
   c. crvUSD -> USDT on Uni v3 0.05% (or PYUSD, whichever quotes the bigger
      premium). This is the premium-capture leg.
   d. USDT -> USDC on Uni v3 0.01% to come back to the Maker bridge.
   e. PSM `sellGem(this, usdcAmt)` to swap USDC -> DAI 1:1.
   f. Repay DssFlash by approving DAI to the flash module.
3. Net = (proceeds from premium leg) - (Curve fee) - (Uni v3 fees) - gas.

## PnL math
Let:
- `N_dai` = flash size (50M DAI)
- `s` = realised premium on Uni v3 crvUSD route (bp, e.g. 30 bp)
- `f_psm` = 0 bp (when tin/tout = 0)
- `f_curve_in` = 1 bp (Curve crvUSD/USDC)
- `f_uni_premium` = 5 bp (Uni v3 0.05% pool fee)
- `f_uni_back` = 1 bp (Uni v3 0.01% USDT/USDC pool)
- `slip_uni` = 5-15 bp on 50M notional through Uni v3 (depends on tick liq)

```
gross = N_dai * s / 1e4
fees  = N_dai * (f_curve_in + f_uni_premium + f_uni_back + slip_uni) / 1e4
gas   = ~700k * gp * ethUsd
net   = gross - fees - gas
```

At s = 30 bp, fees ≈ 12 bp + 10 bp slip = 22 bp -> **net ~8 bp on $50M =
$40k per opportunity**, gross of gas.

Caveat: the premium is *transient*. Each successful arb compresses the Uni
v3 premium back toward peg; the trade is mostly a single-block one-shot
per premium episode.

## Block pinned
**18_500_000** (Oct 26 2023). At that time crvUSD was newly launched and
traded $1.005-$1.012 on Uni v3 `crvUSD/USDC 0.05%` for several days while
Curve `crvUSD/USDC` PegKeeper inventory was $20-40M and the pool stayed
near peg. Multiple searchers ran exactly this trade in Oct-Nov 2023.

Secondary candidate: **19_200_000** (mid-Feb 2024), smaller premium.

## Risks
- **Premium evaporation between block-build and inclusion.** If a competing
  searcher fills the Uni v3 ask first, the trade reverts on `amountOutMin`
  (or returns at a loss if you set min=0). MEV-Share / Flashbots is the
  only practical inclusion path.
- **PSM tin/tout activation.** Maker governance can flip these to 1-10 bps
  via a single MIP12 spell; check `tin()`/`tout()` at the fork block.
- **Maker DSS-Flash global cap.** The 500M ceiling is shared; on a busy
  block another caller can preempt.
- **Curve PegKeeper de-activation.** If the PegKeeper is paused (governance)
  the Curve pool quote diverges materially, breaking the model.
- **Re-org risk.** Same as any cross-domain arb.

## Result
Status: **theoretical, foundry build not run**. Expected per-opportunity
PnL: **+$1k to +$60k** depending on premium magnitude and flash size; the
*opportunity rate* is the limiter (1-3 windows per quarter historically).
Annualised single-searcher EV: **$30k-$150k** assuming no MEV competition
(unrealistic) — **$5k-$30k** under realistic Flashbots backrun
competition.
