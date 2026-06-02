# B05-08: Ethena Reserve-Fund-related basis anomaly (sUSDe APY mean-reversion)

## Mechanism (2-mech, signal-driven)
This is a **positional alpha trade** keyed off the discrepancy between:

- **Ethena's distributed sUSDe APY** (what the protocol actually paid
  out last epoch, observable from `sUSDe.totalAssets()` deltas), vs
- **On-chain perp-funding proxy** (rolling 30-day average of BTC/ETH
  perp funding × 365, observable from public Binance/Bybit APIs and
  approximated on-chain via CEX-funding oracles where available).

Ethena's **Reserve Fund** smooths the distributed APY: when perp funding
is unusually high, Ethena retains the excess in the Reserve Fund and
under-distributes to sUSDe; when funding drops or turns negative, the
Reserve Fund releases yield to keep distributions stable. This creates
a **mean-reverting** gap between the two metrics that is *not* arbed
away because most sUSDe holders are passive.

The strategy:

1. **Long sUSDe with modest leverage** when the perp-funding proxy ≫
   distributed APY (Reserve Fund accumulating → future release expected).
2. **Avoid sUSDe / hold cash** when perp-funding proxy ≪ distributed
   APY (Reserve Fund draining → future cut expected).

Mechanisms used: Ethena sUSDe + Venus (for the levered version). The
strategy is positional and *complementary* to B05-01 (which is the
pure-carry version without any directional signal).

## Why it composes
- The signal is **information**, not a mechanism — but the *implementation*
  uses two on-chain primitives (Ethena + Venus) to lever the conviction.
  When the signal is strong (gap > 300 bps), the 1.5x lever is justified;
  when weak, the position reverts to cash.
- Unlike B05-04's funding-flip rotation (which acts on a *negative*
  funding regime), B05-08 acts on the *gap* between observed and
  distributed APY — works in both regimes (long when gap is positive,
  flat when zero, short-via-cash when gap is negative).
- The Reserve Fund mechanic is publicly documented by Ethena and the
  asymmetry is structural (passive holders don't arb it), so the alpha
  decays only when many actors start front-running the same signal.

## Preconditions
- Off-chain signal source: distributed sUSDe APY (Ethena dashboard or
  on-chain `sUSDe.totalAssets()` delta) and perp-funding proxy
  (Coinglass/Binance/Bybit funding averages).
- Gap |perp_funding − distributed_APY| > 300 bps to trigger entry.
- Venus has a vsUSDe collateral market (for the levered version) — if
  unavailable, the strategy degrades to an unlevered long-sUSDe hold.

## Strategy steps (signal: long sUSDe)
Principal: 100,000 USDe.

1. Compute gap. If < 300 bps, no trade.
2. Stake 100k USDe → sUSDe.
3. Supply sUSDe to Venus, borrow 50k USDT (1.5x effective leverage —
   modest because directional).
4. Swap USDT → USDe (PCS v3 1bp), re-stake to sUSDe.
5. Hold 21 days (Ethena's typical Reserve Fund rebalance cadence).
   During the hold, sUSDe APY reverts from 7% to ~9.5% (modelled mean
   reversion uplift = 250 bps).
6. Unwind: redeem sUSDe, repay USDT debt.

## PnL math (closed-form, 21-day, levered 1.5x)
- Collateral notional: 100,000 × 1.5 = $150,000.
- Debt: $50,000 at 5.5% vUSDT APR.
- Expected sUSDe APY during hold: 7% + 2.5% = 9.5%.
- Gross PnL: 150,000 × 9.5% × 21/365 = **+$820**.
- Borrow cost: 50,000 × 5.5% × 21/365 = **−$158**.
- Swap drag (2x 11 bp on $50k): = **−$110**.
- Net strategy PnL: 820 − 158 − 110 = **+$552**.

Counterfactual: hold spot sUSDe at 7% APY for 21 days:
- 100,000 × 7% × 21/365 = **+$403**.

**Alpha pickup vs counterfactual: 552 − 403 = +$149 over 21 days
(~2.6% annualised alpha on principal).**

The "alpha" is the *signal value* — what an informed sUSDe holder earns
on top of the naïve buy-and-hold. Annualised carry on the levered
position is 9.6%, but only ~2.6% of that is *attributable* to the
signal; the rest is the same carry B05-01 captures.

Gas: ~400k for stake + supply + borrow + swap + re-stake. At 1 gwei ×
$600/BNB ≈ $0.24.

## Block pinned
**43_300_000** — Q1 2025 window where on-chain perp-funding proxy was
~12% annualised while Ethena's distributed sUSDe APY was ~7%
(historical precedent: Reserve Fund accumulated during the Mar 2024
funding spike).

## Addresses used
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe (`BSC.USDe`).
- `0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2` — sUSDe (`BSC.sUSDe`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `BSC.vUSDT`, `BSC.PCS_V3_ROUTER`, `BSC.VENUS_COMPTROLLER`.

## Risks
- **Signal mis-fire**: if Reserve Fund stays under-distributed for
  longer than 21 days (Ethena governance decides to retain), the
  strategy holds the position past the modelled horizon and the alpha
  ages out. Mitigation: cap holding period to 60 days, then exit
  regardless.
- **Wrong-direction signal**: if the gap actually predicts a *cut*
  rather than a release (Reserve Fund accumulating because Ethena
  expects funding to drop), the levered position loses alpha. Cap
  leverage at 1.5x.
- **Venus liquidation on USDe depeg**: levered sUSDe-collateral
  position is liquidatable if USDe drops > 5%. Mitigation: SAFETY_BPS
  on the borrow size + monitoring.
- **Reserve Fund publicly documented → alpha decay**: as more agents
  read Ethena's transparency reports, this trade gets crowded.
  Mitigation: trade only when the gap is large (> 500 bps).

## Result
Status: **theoretical, positional**. Expected alpha: **+$149 on $100k
over 21 days (~2.6% annualised on top of the B05-01 base carry)**.
PoC emits the canonical PnL block with the alpha (vs counterfactual)
settled into the tracked USDT bucket. PoC runs offline-first; the
forked branch exercises the levered long-sUSDe build when both
markets are live at the pinned block.
