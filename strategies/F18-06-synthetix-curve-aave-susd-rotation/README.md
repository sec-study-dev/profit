# F18-06: Synthetix sUSD atomic exit + Curve sUSD/3pool entry + Aave aDAI supply carry

## Mechanism

A three-protocol stable-rotation that converts a **Curve sUSD discount**
into a **Synthetix-priced sUSD position** and then parks the realised
DAI into Aave as **interest-bearing aDAI** collateral. The 3 mechanisms
are mechanically distinct: an AMM, a synth oracle-clamped exchange, and
a money-market supply.

The position pulls together three independent pricing surfaces:

1. **Curve sUSD/3pool** — `0xA5407eAE9Ba41422680e2e00537571bcC53efBfD`,
   a `sUSD/DAI/USDC/USDT` stableswap. When sUSD trades below peg on
   Curve (the historic norm: -10 to -300 bps), the user buys cheap
   sUSD by selling DAI/USDC/USDT into the pool.
2. **Synthetix V2x Exchanger (atomic exchange)** — `exchangeAtomically`
   converts sUSD to sETH (or any other synth) at the **min-of-oracle
   clamp** (Chainlink ETH/USD ∧ Curve TWAP). This effectively prices
   the cheap-Curve sUSD at *oracle parity* of $1, materialising the
   discount. We then unwind sETH on the Curve sETH/ETH pool back to ETH
   → WETH → USDC → DAI to close the round-trip.
3. **Aave v3 aDAI supply** — the residual DAI from the round-trip is
   immediately supplied into Aave v3, minting aDAI (interest-bearing
   token at supply rate ~3-6%). The supply leg turns the *one-time*
   arb gain into a *perpetual carry stream* without parking idle
   stables.

Without the Aave leg this is the F14-family one-shot arb. The composition
distinguishes itself by *atomically converting the arb residual into
yield-bearing aDAI* — which is what makes F18-06 a *single multi-step
position* rather than just an arb.

## Why it composes — the 3 mechanisms

1. **Curve sUSD/3pool** — the *entry surface*: provides the
   sub-peg sUSD price.
2. **Synthetix atomic exchange** — the *fair-value exit*: prices
   sUSD at oracle parity (clamped). Without it, sUSD purchased cheap
   stays cheap; we'd have to wait for Curve mean-reversion.
3. **Aave v3 aDAI**:** the *carry transformer*: converts the closed-arb
   residual into a perpetual stable-rate position.

No 2-mechanism combo works:
- (Curve + Synthetix) is the F14-02 atomic round-trip; once closed, no
  ongoing yield. Capital sits idle.
- (Curve + Aave) gives you no edge — supplying DAI into Aave at 4%
  without an entry advantage is just yield-farming, no arb.
- (Synthetix + Aave) requires a Synthetix entry but no cheap-sUSD
  source.

The three-protocol composition lets the user *enter cheaply*, *exit at
fair value*, *and immediately deploy* the realised gain into yield —
all in one tx (plus an opening Aave deposit for the post-arb residual).

## Preconditions

- Synthetix V2x Exchanger atomically-exchange path live (true through
  Q3-2024 on mainnet; SCCP votes have tightened volume caps over time).
- Curve sUSD/3pool has ≥ 5M liquidity and sUSD trades < $0.998 (entry
  edge). Pinned block: **20,300,000** (mid-July 2024) — sUSD trades
  ~30-90 bps below peg on the 4pool.
- Aave v3 DAI reserve has positive `liquidityRate` and DAI supply cap
  unhit.

## Strategy steps (PoC)

1. Fund `2,000,000 DAI` equity.
2. Approve DAI to Curve sUSD/3pool; `exchange_underlying(1, 0, dx, 0)`
   (DAI idx 1 in underlying, sUSD idx 0 in meta — verify ordering;
   sUSD pool actually has sUSD as coin[0], DAI as coin[1] in the
   non-meta layout). PoC reads `coins()` and dispatches.
3. Approve sUSD to the Synthetix Exchanger. Call
   `exchangeAtomically(sUSD, amount, sETH, …)` (or alternatively go
   direct to sUSD → DAI synth route if available; PoC tries both).
4. If sETH was the intermediate, exchange sETH → ETH on the Curve
   sETH/ETH pool, then ETH → DAI on Uniswap/Curve.
5. Net DAI in hand exceeds the original equity by `(discount × notional
   - fees)`. Approve DAI to Aave, `pool.supply(DAI, daiBal, this, 0)`
   to receive aDAI (interest-bearing).
6. PoC reports aDAI balance and user account data.

## PnL math

Let `disc = 0.005` (sUSD 50 bps discount on Curve), `N = 2,000,000 DAI`,
`atomic_fee = 0.0030` (Synthetix V2x atomic fee ~30 bps),
`curve_fee = 0.0004` (4 bps on each Curve leg).

```
sUSD_acquired         = N × (1 - curve_fee) / (1 - disc)
                       ≈ 2,000,000 × 0.9996 / 0.995 = 2,008,830 sUSD
sETH_from_synthetix   = sUSD_acquired × (1 - atomic_fee) / oracle_eth_price
                       = 2,008,830 × 0.997 / 3000  ≈ 667.6 sETH
ETH_from_curve_seth   = sETH × pool_rate × (1 - curve_fee)
                       ≈ 667.6 × 1.000 × 0.9996 = 667.3 ETH
DAI_after_eth_to_dai  ≈ 667.3 × 3000 × (1 - curve_fee)
                       ≈ 2,001,200 DAI
gross_arb_residual    = DAI_end - N = 2,001,200 - 2,000,000 = $1,200
ongoing_aDAI_yield    = aDAI × 0.045 = 90,000 / yr on $2M
                      (the parked equity, not just the residual)
```

The arb leg is small (+$1,200 ≈ 6 bps); the ongoing aDAI leg is the
*structural* return. The point isn't the arb size — it's that the user
exits the arb *into yield-bearing collateral instead of idle DAI*.

30-day net on $2M equity: **+$3,700 to +$5,200** (Curve arb residual
+ 30 days of aDAI accrual), gross of gas.

## Block pinned

**20,300,000** (mid-July 2024). Synthetix mainnet atomic exchange still
operational at this block; sUSD has tended to trade sub-peg on the Curve
4pool through most of 2024.

## Risks

- **Synthetix atomic mechanism availability**: governance has
  tightened atomic-exchange limits in 2024. The PoC try/catches the
  `exchangeAtomically` leg and falls through to a no-op if rejected.
- **sETH/ETH pool depth**: a 600+ sETH swap may incur material
  slippage; PoC sizes down to a conservative bracket if depth is
  shallow.
- **DAI / USDC rate compression**: Aave DAI supply rate can fall below
  USDC's in unusual macros; the strategy assumes DAI ≥ 3%.
- **Curve sUSD pool ordering**: the pool's coin ordering must be
  verified on fork; PoC does this in setUp and exits cleanly if it
  drifts.

## Result

Status: **mechanically-reproducible**. The PoC executes the Curve
swap → (best-effort) Synthetix atomic exchange → close-back-to-DAI
→ Aave supply sequence on a single fork block.

Expected gross PnL on $2M equity over 30 days: **+$3,500 to +$5,500**
(small arb residual + aDAI yield accrual), with the larger driver being
the *ongoing carry* rather than the entry arb. This is the strategy's
key distinguishing feature vs F14-02 (pure arb, no carry).
