# B11-07: asBNB + Pendle YT-asBNB + Lista Lending triple

## Mechanism
3-mechanism levered points farm. Unlike B11-05 (PT-asBNB lock) and
B11-03 (50/50 PT+YT split), this strategy goes **explicitly long the YT**
and borrows lisUSD on Lista Lending to scale the YT position without
unwinding the asBNB collateral. YT-asBNB captures the entire Astherus
points stream at high implied leverage — every dollar of YT face value
gives ~20× exposure to the underlying points stream.

1. **Astherus asBNB** (mechanism 1) — 100 BNB principal becomes ~97.56
   asBNB. Earns validator yield + Astherus points; Astherus accrues to
   the underlying share even while the token is supplied to Lista.
2. **Lista Lending lisUSD borrow** (mechanism 2) — supply 100 asBNB as
   collateral, borrow lisUSD up to ~50 % LTV × 90 % safety ≈ 45 BNB-equiv.
3. **Pendle YT-asBNB long** (mechanism 3) — swap borrowed lisUSD →
   WBNB → BNB → asBNB → YT-asBNB. YT bleeds yield in cash form: stake
   APY (3.8 %) + Astherus points (1.0 % USD-equiv assumption) flow to
   the YT holder until expiry, at which point YT → 0.

## Why it composes
- The base asBNB layer **never moves** during the 90-day window: it sits
  in Lista Lending the whole time accruing Astherus rewards.
- The borrowed-leg asBNB is *immediately* converted to YT, so the points
  exposure on that 45-BNB notional is captured at the YT premium (~20×
  implied leverage on points).
- Three distinct revenue sources: validator yield on the base, YT cash
  flow stripped from a separate asBNB unit, and the spread between Lista
  lisUSD borrow APR and the YT implied yield.

## Preconditions
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.LISTA_LENDING`,
  `BSC.PENDLE_ROUTER_V4`, `LOCAL_MARKET_ASBNB`, `LOCAL_YT_ASBNB` all live.
- Pendle market for asBNB has TVL ≥ 1 M BNB-equiv (YT slippage tolerance).
- Lista Lending accepts asBNB as collateral with CF ≥ 0.50.

## Strategy steps
1. Start with 100 BNB native principal.
2. `ASTHERUS_STAKE_MANAGER.deposit{value: 100}()` → ~97.56 asBNB.
3. `LISTA_LENDING.supply(asBNB, 97.56, self)`.
4. Read `getUserAccountData` → derive borrowable; apply 90 % safety.
5. `LISTA_LENDING.borrow(lisUSD, ~45e18, self)`.
6. `PCS_V3.exactInputSingle(lisUSD → WBNB)` → ~45 WBNB → unwrap.
7. `ASTHERUS_STAKE_MANAGER.deposit{value: 45}()` → ~43.9 asBNB.
8. `PENDLE_ROUTER_V4.swapExactTokenForYt(self, market, 0, input)` →
   YT-asBNB at the market quote.
9. Hold 90 days; YT decays to 0; refresh asBNB oracle and zero out YT.
10. Emit standard PnL block.

## PnL math
Indicative rates at block 45,500,000:
- asBNB stake APY: 3.8 %
- Astherus points APY (USD-equiv assumption): 1.0 %
- YT implied yield: 4.8 % (face value = stake + points combined)
- Lista Lending lisUSD borrow APR: 2.8 %
- PCS v3 lisUSD↔WBNB slippage: 0.10 % one-off

90-day flows on 100 BNB principal:
| Leg | Notional | Rate | 90d BNB |
|---|---|---|---|
| Base asBNB hold (in Lista) | 100 | +4.8 % | +1.183 |
| Lista lisUSD borrow cost | 45 | −2.8 % | −0.311 |
| YT cashflow capture | 45 | +4.8 % | +0.519 |
| PCS slip one-off | 45 | −0.10 % | −0.045 |

Net = **+1.34 BNB per 100 BNB over 90 days** ≈ **+$806** ≈ 5.4 % APR-equiv.

### Sensitivity
- Points realise at zero → YT bleeds (full 4.8 % implied yield missed):
  net drops to **+0.55 BNB**.
- Points realise at ezETH-tier (3 % USD/yr) → net climbs to **+1.7 BNB**.

Gas: ~4 staking/swap calls + Pendle swap ≈ 700 k gas ≈ $0.42.

## Block pinned
**45,500,000** — TODO re-pin. Offline-first with documented-rates
fallback.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.asBNB` — **TODO verify**.
- `BSC.LISTA_LENDING` — **TODO verify** (placeholder in BSC.sol).
- `BSC.PENDLE_ROUTER_V4` — **TODO verify** (reused from mainnet).
- `LOCAL_MARKET_ASBNB`, `LOCAL_YT_ASBNB` — placeholders.
- `BSC.lisUSD`, `BSC.WBNB`, `BSC.PCS_V3_ROUTER` — verified.

## Risks
- **YT principal risk.** YT-asBNB face decays to 0; if Astherus points
  realise below the 4.8 % implied threshold the YT leg is loss-making.
- **Lista LTV cut.** asBNB CF on Lista Lending is speculative; an LTV cut
  forces partial liquidation of the asBNB collateral.
- **Pendle market depth.** YT swap slippage scales with size; 45 BNB
  through a small market may impact 1-2 % on entry. Bounded by trying
  smaller batches if `swapExactTokenForYt` reverts.
- **lisUSD depeg.** Atomic mint→swap minimizes inventory exposure.
- **Points valuation.** Same caveat as B11-01/03.

## Result
Status: **theoretical** (offline-first; 4+ TODO-verify addresses).
Expected PnL **+0.5–1.7 BNB per 100 BNB over 90 days** depending on
points realisation. Strictly leveraged on the points realisation
assumption; downside-protected by the base asBNB hold (+1.18 BNB base
case) if YT goes to zero with no points.
