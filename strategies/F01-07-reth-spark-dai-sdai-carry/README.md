# F01-07: rETH on Spark, borrow DAI, redeploy to sDAI for DSR carry

## Mechanism
A three-mechanism leveraged LST position that combines:

1. **Rocket Pool rETH** (`Mainnet.RETH`) as the yield-bearing collateral. rETH
   appreciates at the protocol's `getExchangeRate()` rate (~3.0-3.4% APR net
   of Rocket node-operator commission), no rebasing.
2. **Spark Protocol** (`Mainnet.SPARK_POOL`, an Aave v3 fork) as the lending
   venue. Spark lists rETH as collateral with conservative LTV (~74% standard,
   no e-mode for rETH at most blocks because Spark's e-mode is reserved for
   wstETH and sDAI). Spark's borrow asset of interest here is **DAI**, whose
   variable rate is pegged to the **Maker Pot DSR + a small spread**.
3. **MakerDAO sDAI ERC-4626 wrapper** (`Mainnet.SDAI`) — wrapping idle DAI to
   `sDAI` yields the Pot DSR (`pot.dsr()` accreted in `chi`), historically
   3-8% APR.

Conventional rETH-on-Aave looping (F01-03) borrows WETH and re-routes to rETH.
This strategy *does not loop back into rETH*; instead it borrows DAI and
parks it in sDAI. The economic structure is therefore:

- Asset leg: `principal * 1` of rETH at yield `s_rETH ≈ 3.2%`.
- Debt leg: `D` DAI borrowed at Spark variable rate `b_spark_DAI`.
- Hedge leg: same `D` DAI deposited to sDAI at DSR rate `s_DSR`.

Because Spark's DAI rate is calibrated against DSR + ~25 bp spread, the
*debt-hedge net cost* is `b_spark_DAI - s_DSR ≈ 0.25%`. That cost is paid in
DAI but the principal exposure is fully in rETH — so the strategy captures
the full rETH yield against only a 25 bp drag on the borrowed notional, plus
whatever rETH/USD direction the holder takes. It is a *carry-funded LST
exposure* rather than a leveraged LST loop.

## Why it composes
This composition explicitly uses **THREE distinct DeFi mechanisms**:

1. **Rocket Pool rETH (LST)** — the underlying yielding asset.
2. **Spark Protocol borrow-side (Aave v3 fork lending market)** — the
   leverage / borrowing primitive. Critically, Spark's DAI rate is *not*
   utilisation-discovered like Aave's: it is governance-set to **track DSR
   closely**, making it a unique borrow venue where the rate is mechanistically
   tied to a different rate (DSR) rather than to market supply/demand.
3. **MakerDAO Pot DSR via sDAI ERC-4626** — the *destination* of the borrowed
   DAI. This is the hedge against the borrow rate: because Spark DAI rate ≈
   DSR + spread, depositing borrowed DAI into sDAI converts the borrow leg
   from a "drag of `b`" into a "drag of `b - DSR ≈ spread`".

The composition is therefore a **three-protocol triangle**: Rocket Pool ↔
Spark ↔ Maker (via DSR/sDAI). Without the sDAI hedge leg this is a naked
borrow that pays the full `b`; without the rETH leg there is no asset
exposure; without Spark there is no leverage mechanism. The strategy works
*because* Spark's DAI borrow rate is mechanically tied to the same Pot DSR
that sDAI returns — this is the "rate-anchor" alpha unique to the Maker
ecosystem on Spark.

Note that this composition is fundamentally different from F10-02 (which
loops sDAI itself as collateral). Here sDAI is *not* posted as collateral on
Spark; it's parked as an outside-vault hedge against the DAI debt.

## Preconditions
- Mainnet block where Spark lists rETH as collateral with non-zero borrow cap.
- Block snapshot: Spark DAI variable APR `b` close to DSR + 25-50 bp.
- Block snapshot: `rETH_yield + (DSR - b)` > 0. Since DSR ≤ b by construction,
  this reduces to `rETH_yield > b - DSR`, i.e. `rETH yield > 25-50 bp` — easily
  satisfied (rETH yield ~3%).
- rETH supply cap headroom on Spark.

## Strategy steps
1. WETH → ETH → rETH via Curve rETH/ETH pool.
2. Approve rETH to Spark; `supply(rETH, amount)`.
3. Borrow DAI at variable rate. Borrow target: `Bmax * LTV_BPS` where Bmax is
   Spark headroom and LTV_BPS = 0.85 of max (e.g. 0.74 LTV × 0.85 ≈ 0.63).
4. Deposit borrowed DAI into sDAI via `ISDAI.deposit(dai, address(this))`.
5. Park 30 days.
6. PnL crystallises as: rETH appreciation + sDAI appreciation − Spark DAI
   accrued interest.

## PnL math
Let:
- `s_rETH` = rETH internal yield APR ≈ 0.032
- `s_DSR` = MakerDAO Pot DSR ≈ 0.080 (pinned-block snapshot; April-2024 was
  8% before downgrade)
- `b_spark` = Spark DAI variable APR ≈ 0.085 (DSR + ~50 bp at the pinned block)
- `principal_ETH` = 100 ETH
- `LTV_eff` = 0.60 (conservative)
- `D` = principal_ETH * ETH_USD * LTV_eff (DAI borrowed)

Per 30 days on 100 ETH @ ETH = $2.5k:
```
rETH_carry  = 100 * 0.032 * 30/365         = +0.263 ETH      (~ +$657)
D           = 100 * 2500 * 0.60            = 150_000 DAI
sDAI_carry  = 150_000 * 0.080 * 30/365     = +986 DAI        (~ +$986)
spark_cost  = 150_000 * 0.085 * 30/365     = -1047 DAI       (~ -$1047)
net_per_30d = +$657 + $986 - $1047 = +$596  (≈ +0.24 ETH)
```

So on 100 ETH principal we extract roughly `+$600 / 30d ≈ 2.4% APR effective`
on the principal, *plus* the directional rETH exposure (which is the
underlying reason to do the trade — leveraged exposure isn't needed to print
the carry alpha).

Comparing to F01-03 (`+0.55 ETH / 30d` on the same principal): F01-07 is
smaller magnitude carry but lower-leverage and exposes the operator to a
different rate basis (Spark DAI vs Aave WETH).

## Block pinned
**19_700_000** (Apr 2024) — Spark rETH listing live; DSR observed at 8% prior
to the May-2024 reduction to 5%; Spark DAI borrow rate observed at ~8.5%;
Curve rETH/ETH pool depth ample.

## Risks
- **DSR governance cut**: Maker can cut DSR independently of Spark DAI rate;
  if DSR drops faster than Spark DAI rate, the hedge widens negatively. The
  spread is governance-managed so the gap is bounded but not zero.
- **rETH peg / Rocket smart-contract**: same as F01-03.
- **Spark DAI rate ramp**: at high DAI utilisation Spark's variable rate kink
  decouples from DSR; sustained ramps make the carry leg negative.
- **No leverage = no acceleration**: the strategy does not multiply the
  rETH leg; gross yield is in absolute dollars, not multiplied APR.
- **DAI/USD depeg**: DAI trading <0.99 forces sDAI carry to mark down on
  exit; can erase weeks of carry.

## Result
Status: theoretical (Spark rETH listing verified via Spark docs / on-chain
`getReserveData`; sDAI is canonical Maker ERC-4626; PoC compiles).
Expected PnL at pinned block: **+0.2% to +0.3% over 30 days** (≈ +0.2 ETH on
100 ETH principal) net of all three legs. Lower magnitude than F01-01..06
because there is no leverage multiplier — but it cleanly demonstrates the
**three-mechanism cross-protocol triangle** that gives the LST holder a
DSR-pegged carry on top of rETH appreciation.
