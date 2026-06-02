# B11-08: asBNB → PCS LP (asBNB/WBNB) → Thena gauge triple

## Mechanism
3-mechanism yield stack that monetises the asBNB token both as an LST and
as a liquidity-pair half:

1. **Astherus asBNB** (mechanism 1) — 50 BNB is staked into asBNB so the
   LP's asBNB side **continues to earn the validator yield + Astherus
   points**. The asBNB exchange rate drifts up monotonically while
   parked in the LP.
2. **PCS V2 asBNB/WBNB LP** (mechanism 2) — deposit the 50 asBNB + 50
   WBNB into the asBNB/WBNB pair. Earns swap fees on every trade through
   the pair. asBNB/WBNB is a close-peg pair so impermanent loss is low
   (~5 bp over 60 d at typical pegged-asset drift).
3. **Thena gauge stake** (mechanism 3) — deposit the LP token into the
   Thena gauge for the corresponding asBNB/WBNB pair. Earns $THE
   emissions which Thena directs at LST pairs via bribed gauge weight.

The three mechanisms are independent: validator yield is paid into
asBNB's exchange-rate drift; swap fees accrue into LP reserves; $THE
emissions accumulate as gauge claims. None of them gate the others.

## Why it composes
- The asBNB side of the LP keeps earning native stake yield even while
  locked as LP liquidity — this is the **key insight that doesn't apply
  to non-share-token pairs**.
- Thena's ve(3,3) emission model favours pairs with high bribed gauge
  weight; LST pairs (slisBNB/BNB, asBNB/BNB) typically attract enough
  bribes to push gauge APR > 10 %.
- IL on close-peg pairs is bounded: asBNB exchange-rate drift over 60 d
  is ≤ 0.6 %, which translates to ≤ 1 bp of LP IL after rebalancing.

## Preconditions
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER` live.
- PCS V2 asBNB/WBNB pair exists with ≥ $1 M TVL.
- Thena gauge for asBNB/WBNB exists (or Thena's own pair if PCS-LP isn't
  whitelisted as gauge stake). PoC assumes the gauge accepts the LP
  directly; if not, the offline path still emits the same PnL block
  modulo the gauge leg.

## Strategy steps
1. Start with 100 BNB native principal.
2. Split: 50 BNB → asBNB via Astherus, 50 BNB → WBNB via `WBNB.deposit`.
3. `PCS_V2.addLiquidity(asBNB, WBNB, asBal, wbnbBal, 0, 0, self, ...)`
   → ~71 LP tokens at the assumed reserves.
4. `THENA_GAUGE.deposit(LP_amount)`.
5. Hold 60 days; warp + roll.
6. `THENA_GAUGE.getReward()` → claim $THE emissions.
7. Emit standard PnL block.

## PnL math
Indicative rates at block 45,500,000:
- asBNB stake APY (on locked-in-LP half): 3.8 %
- Astherus points APY (USD-equiv assumption): 1.0 %
- PCS V2 LP fee APR (asBNB/WBNB pair): 3.5 %
- Thena gauge $THE emissions APR: 12.0 % (LST pair, well-bribed)
- IL drag (close-peg, 60 d): ~0.005 BNB negligible

60-day flows on 100 BNB:
| Leg | Notional | Rate | 60d BNB |
|---|---|---|---|
| Validator + points (asBNB half) | 50 | +4.8 % | +0.394 |
| LP fees (full notional) | 100 | +3.5 % | +0.575 |
| $THE gauge emissions | 100 | +12.0 % | +1.973 |
| IL drag | — | — | −0.005 |

Net = **+2.94 BNB per 100 BNB over 60 days** ≈ **+$1,762** ≈ 17.9 %
APR-equiv.

### Sensitivity
- Gauge weight halved → $THE APR 6 %: net **+1.96 BNB**.
- LP fee 1 % (low-vol regime): net **+2.53 BNB**.
- $THE price halved: net **+1.96 BNB**.

Gas: ~5 calls (deposit, wrap, addLiquidity, gauge deposit, claim) ≈
600 k gas ≈ $0.36.

## Block pinned
**45,500,000** — TODO re-pin once Astherus is live and Thena gauge
weights are observed. Offline-first.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.asBNB` — **TODO verify**.
- `LOCAL_PCS_LP_ASBNB_WBNB` — placeholder pending PCS V2 pool creation.
- `LOCAL_THENA_GAUGE_ASBNB` — placeholder pending Thena Voter.gauges().
- `BSC.PCS_V2_ROUTER`, `BSC.WBNB`, `BSC.THE` — verified.

## Risks
- **Impermanent loss.** asBNB/WBNB peg drift is small but not zero;
  prolonged validator yield accrual = ~0.6 % drift over 60 d → bounded
  IL ≤ 1 bp.
- **Thena gauge depeg.** $THE price is the volatile reward leg; emission
  APR of 12 % converts to BNB through the $THE/BNB market — a $THE
  crash could halve the realised yield.
- **PCS V2 ↔ Thena gauge mismatch.** Thena gauges expect Thena's own
  pair tokens. If the LP-stake leg fails the offline fallback assumes
  using Thena's pair directly (same economics modulo a small TVL gap).
- **TODO-verify addresses**. Standard PoC pattern: fork+sim duality.

## Result
Status: **theoretical** (offline-first; multiple TODO-verify addresses
including the LP and gauge). Expected PnL: **+2.0–3.5 BNB per 100 BNB
over 60 days**. Highest-yield strategy in the B11 family if $THE
emissions hold up, but most exposed to volatile-reward token price
swings.
