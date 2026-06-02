# B11-05: asBNB + Lista CDP + Pendle PT-asBNB triple stack

## Mechanism
Three orthogonal yield mechanisms layered on a single 100 BNB principal —
no recursive leverage, no liquidation cascade, but all three protocols
earn simultaneously on the same base asset.

1. **Astherus asBNB** (mechanism 1) — base LST. Earns the BNB validator
   yield (~3.8 %) plus Astherus restake / AVS points (1.0 % USD-equiv
   assumption).
2. **Lista CDP** (mechanism 2) — deposit asBNB as collateral in the Lista
   DAO Interaction contract, mint lisUSD up to 65 % LTV × 90 % safety =
   ~58.5 % effective. The freshly minted lisUSD is swapped to WBNB on
   PCS v3 and unwrapped, providing fresh BNB capital without unwinding the
   asBNB base.
3. **Pendle PT-asBNB** (mechanism 3) — the borrowed BNB is restaked into
   asBNB and locked into a 90-day PT-asBNB position to fix-in the asBNB
   maturity discount (~4.5 % implied APY). PT pulls toward 1.0 asBNB at
   expiry, generating a deterministic BNB cash-and-carry on top of the
   leveraged base.

Compared to B11-01/02 the leverage is one-shot (no iteration), but every
unit of BNB exits the loop earning **three independent income streams**.

## Why it composes
- All three mechanisms accept asBNB cleanly: Lista CDP whitelists it as
  collateral (per Astherus×Lista partnership), Pendle markets exist for
  asBNB (B04-05/B04-07 confirm tooling), and Astherus is the mint side.
- The PCS v3 lisUSD→WBNB hop is the only fee burn. ~0.10 % round-trip
  slippage at ≤ 60 BNB per swap.
- Yields are additive, not correlated: validator yield, CDP stable-borrow
  spread, and Pendle PT maturity discount have **different IRMs**. A
  spike in lisUSD borrow rate doesn't reduce the PT lock; a Pendle market
  flatness doesn't dent the underlying validator yield.

## Preconditions
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.LISTA_INTERACTION`,
  `BSC.PENDLE_ROUTER_V4`, `LOCAL_MARKET_ASBNB`, `LOCAL_PT_ASBNB` all live
  at the pinned block.
- Lista CDP accepts asBNB as collateral type.
- Pendle PT-asBNB market has TVL ≥ 1 M BNB-equiv for slippage tolerance.

## Strategy steps
1. Start with 100 BNB native principal.
2. `ASTHERUS_STAKE_MANAGER.deposit{value: 100}()` → ~97.56 asBNB.
3. `LISTA_INTERACTION.deposit(self, asBNB, 97.56)`.
4. `LISTA_INTERACTION.borrow(asBNB, ~60e18 lisUSD)` (58.5 % LTV).
5. `PCS_V3.exactInputSingle(lisUSD → WBNB, fee=0.25 %)` →
   `WBNB.withdraw()` → ~60 BNB native.
6. `ASTHERUS_STAKE_MANAGER.deposit{value: 60}()` → ~58.5 asBNB.
7. `PENDLE_ROUTER_V4.swapExactTokenForPt(self, market, 0, input)` →
   PT-asBNB at ~4.5 % implied APY.
8. Hold 90 days; PT → 1 asBNB; warp + refresh oracle from
   `convertToAssets(1e18)`.
9. Emit standard PnL block.

## PnL math
Indicative rates at block 45,500,000:
- asBNB stake APY: 3.8 %
- Astherus points APY (USD-equiv assumption): 1.0 %
- Lista CDP stability fee: 4.0 %
- PT-asBNB implied APY: 4.5 %
- PCS v3 lisUSD↔WBNB slippage: 0.10 % (one-off)

90-day flows on 100 BNB:
| Leg | Notional | Rate | 90d BNB |
|---|---|---|---|
| Base asBNB hold | 100 | +4.8 % | +1.183 |
| CDP borrow cost | 60 | −4.0 % | −0.591 |
| PT lock (60 BNB) | 60 | +4.5 % | +0.666 |
| PCS slip one-off | 60 | −0.10 % | −0.060 |

Net = **+1.20 BNB per 100 BNB over 90 days** ≈ **+$720** at $600/BNB ≈
4.9 % APR-equiv.
With points valued at zero → +0.80 BNB; with ezETH-tier points → +2.0 BNB.

Gas: ~6 external calls + deposit + Pendle swap ≈ 800 k gas ≈ $0.48 at
1 gwei (negligible).

## Block pinned
**45,500,000** — TODO re-pin once Astherus + Lista CDP whitelisting and
Pendle PT-asBNB market are all confirmed live. Offline-first.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER` — **TODO verify**.
- `BSC.asBNB` — **TODO verify**.
- `BSC.LISTA_INTERACTION` — **TODO verify**.
- `BSC.PENDLE_ROUTER_V4` (reused from mainnet) — **TODO verify**.
- `LOCAL_MARKET_ASBNB`, `LOCAL_PT_ASBNB` — placeholders pending Pendle BSC
  market listing.
- `BSC.lisUSD`, `BSC.WBNB`, `BSC.PCS_V3_ROUTER` — verified.

## Risks
- **Three TODO-verify addresses** in critical positions (Astherus, Lista
  CDP, Pendle). PoC's fork+simulation duality keeps this honest.
- **lisUSD depeg in transit.** Mint → swap is atomic, so the position
  never accrues lisUSD inventory; transient depeg ≤ 0.5 % at swap moment.
- **PT maturity is binding.** Unlike B11-01 which can unwind at will,
  exiting PT-asBNB pre-maturity costs Pendle implied-rate slippage.
- **Lista CDP collateral cap.** asBNB collateral cap could be modest at
  launch; size below the cap to avoid forced redemption.
- **Points valuation.** 1 % APY is an assumption.

## Result
Status: **theoretical** (offline-first; 4+ addresses still TODO verify).
Expected PnL **+1.0–1.5 BNB per 100 BNB over 90 days**. Strictly additive
to validator yield; if any one mechanism fails the strategy still earns
the other two.
