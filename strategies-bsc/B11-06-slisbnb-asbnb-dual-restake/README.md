# B11-06: slisBNB + asBNB dual-restake (parallel points farm)

## Mechanism
BSC analogue of mainnet F18-05 (same-user triple-restake). Split 100 BNB
principal across **two** distinct restake LSTs in a single tx so the same
underlying BNB exposure simultaneously qualifies for both protocols'
points programs:

1. **Lista DAO slisBNB** — 50 BNB deposited via
   `LISTA_STAKE_MANAGER.deposit{value: 50}()`. Earns ~3.6 % validator
   yield + $LISTA emissions + Lista loyalty points.
2. **Astherus asBNB** — 50 BNB deposited via
   `ASTHERUS_STAKE_MANAGER.deposit{value: 50}()`. Earns ~3.8 % validator
   yield + Astherus restake / AVS points.

The position-level alpha is *not* yield maximisation (a single all-asBNB
or all-slisBNB position would slightly outperform pre-points), but rather
**parallel points accumulation**. Each protocol attributes points strictly
to its own share token, so the user simply qualifies twice on the same
BNB capital base.

## Why it composes
- Both protocols accept native BNB → mint a non-rebasing share token, so
  the two deposits are independent state.
- $LISTA emissions are already live and trading; Astherus points have a
  speculative $AST airdrop pending — these are **uncorrelated reward
  streams**.
- The exit path is independent: each LST has its own delayed-withdraw
  queue. If one protocol pauses, the other half is still usable.
- Diversifies protocol-failure exposure: a Lista exploit or an Astherus
  exploit only impacts 50 % of principal.

## Preconditions
- `BSC.slisBNB`, `BSC.LISTA_STAKE_MANAGER` live (verified).
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER` live (TODO verify in BSC.sol).

## Strategy steps
1. Start with 100 BNB native principal.
2. `LISTA_STAKE_MANAGER.deposit{value: 50}()` → ~48.5 slisBNB.
3. `ASTHERUS_STAKE_MANAGER.deposit{value: 50}()` → ~48.78 asBNB.
4. Hold 60 days (`vm.warp`); both exchange rates drift up.
5. Refresh oracle overrides from `convertToBNB` and `convertToAssets`.
6. Emit standard PnL block.

## PnL math
Indicative rates at block 45,500,000:
- slisBNB stake APY: 3.6 %
- $LISTA emissions APY (USD-equiv): 1.5 %
- asBNB stake APY: 3.8 %
- Astherus points APY (USD-equiv assumption): 1.0 %

60-day flows on 100 BNB principal (split 50/50):
| Leg | Notional | Combined APY | 60d BNB |
|---|---|---|---|
| slisBNB + $LISTA | 50 | +5.10 % | +0.419 |
| asBNB + points | 50 | +4.80 % | +0.394 |
| **Total** | 100 | **+4.95 %** | **+0.813** |

Net = **+0.81 BNB per 100 BNB over 60 days** ≈ **+$488** at $600/BNB.

Comparison to single-LST baselines:
- All slisBNB: +0.84 BNB (−0.03 vs dual).
- All asBNB: +0.79 BNB (+0.02 vs dual).

The −0.03 BNB penalty vs all-slisBNB is the **insurance premium** paid
for protocol diversification + dual airdrop qualification. If asBNB
points realise at ezETH-tier (~3 % USD/yr) the dual position outperforms
either single-LST baseline by 0.2-0.4 BNB. With $AST at zero the strategy
is still net +0.81 BNB.

Gas: ~2 staking calls + 2 oracle reads ≈ 250 k gas ≈ $0.15 (negligible).

## Block pinned
**45,500,000** — TODO re-pin once Astherus is confirmed live. Offline-first;
either protocol missing → simulation path.

## Addresses used
- `BSC.LISTA_STAKE_MANAGER`, `BSC.slisBNB` — verified.
- `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.asBNB` — **TODO verify**.

## Risks
- **Astherus protocol risk.** New restake protocol, smaller auditor base.
  Mitigation: only 50 % of principal is exposed.
- **slisBNB de-peg / Lista governance.** Same as in B01-01. The dual-LST
  structure means a partial de-peg only hits one leg.
- **Points valuation.** Both legs' points (LISTA emissions + Astherus
  points) are speculative; the BNB-denominated leg alone (3.7 % blended
  stake APY) is still net positive over the hold horizon.
- **Async redemption.** Both LSTs have 7-15 day unbond queues. Emergency
  exit via PCS swaps will burn ~0.3-0.5 % slippage per leg.

## Result
Status: **theoretical** (offline-first; Astherus side still TODO verify).
Expected PnL: **+0.7-1.4 BNB per 100 BNB over 60 days** depending on
points realisation. Strictly diversification-positive; downside vs
all-slisBNB ≤ 0.03 BNB.
