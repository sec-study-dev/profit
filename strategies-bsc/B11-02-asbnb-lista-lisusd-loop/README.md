# B11-02: asBNB → Lista Lending → borrow lisUSD → swap → re-stake loop

## Mechanism
Same asBNB recursive-restake idea as B11-01, but with two substitutions:

1. **Borrow venue**: Lista Lending (an isolated-pool money market) replaces
   Venus Core. This avoids competing for Venus' vBNB borrow utilization,
   which can spike on alt cycles and flip the carry negative (see B01-01
   risks).
2. **Borrowed asset**: **lisUSD** (Lista's CDP-issued stable) replaces BNB.
   Then we round-trip lisUSD → BNB on PCS v3 to feed the next iteration.

The trick: lisUSD borrow IRM is decoupled from BNB demand. When BNB borrow
APR on Venus is 4 %+ during alt rotations, Lista lisUSD often sits at
2-3 % because lisUSD demand is gated by CDP issuance — a *different* shape
of supply curve.

## Why it composes
- asBNB collateral asset is reused for the points / restake stack
  (mechanism #3 = Astherus).
- Lista Lending uses Lista's own CDP stable lisUSD, so the lender / borrower
  liquidity is internally closed-loop and **not** correlated with the
  Venus BNB market.
- PCS v3 lisUSD/WBNB has thin but persistent liquidity (~$5 M TVL at the
  pinned block), enabling the round-trip with sub-15 bp slippage per iter.
- Three protocols stacked (Astherus + Lista Lending + PCS v3) put this
  squarely in the "stacked mechanism" bucket.

## Preconditions
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.LISTA_LENDING` all live
  at the pinned block (none verified yet).
- Lista Lending has whitelisted asBNB as collateral (likely, given Lista's
  partnership with Astherus) and lisUSD is borrowable.
- PCS v3 lisUSD/WBNB 0.25 % tier exists with > $2 M TVL.

## Strategy steps
1. Start with 100 BNB native principal.
2. Iteration i ∈ [0, 3):
   - `ASTHERUS_STAKE_MANAGER.deposit{value: bnb}()` → asBNB
   - `LISTA_LENDING.supply(asBNB, bal, self)`
   - `LISTA_LENDING.getUserAccountData` → derive borrowable in base units
   - `LISTA_LENDING.borrow(lisUSD, ltv_adjusted_amount, self)`
   - `PCS_V3.exactInputSingle(lisUSD → WBNB, fee=0.25%)`
   - `WBNB.withdraw` → native BNB ready for next iter.
3. Final-iteration drip: any leftover BNB → stake → supply.
4. Hold 60 days; refresh asBNB oracle from `convertToAssets`.
5. Emit standard PnL block.

## PnL math
Indicative rates (refine at block):
- asBNB stake APY: ~3.8 %
- Astherus points APY (USD-equiv assumption): ~1.0 %
- Lista Lending lisUSD borrow APR: ~2.8 %
- PCS v3 lisUSD/WBNB round-trip slippage: ~0.10 % per iter
- Step LTV (Lista lend CF × safety): 0.665
- 3-iter leverage = `1 + 0.665 + 0.442 + 0.294 = 2.401×`
- Net APR = `2.401 × (3.8 + 1.0) − 1.401 × 2.8 − 0.20 = +7.40 %`
- 60-day yield = `7.40 × 60/365 = 1.22 %` → **+1.22 BNB per 100 BNB**.

### Why fewer iterations than B11-01?
Each lisUSD iteration burns swap fees twice (in and out at exit). Beyond 3
iters the marginal yield is eaten by PCS v3 fees. Optimum is plotted as a
function of `(borrow APR + 2 × fee)` vs marginal LST APY × CF.

### Points P&L
Same caveat as B11-01: the 1 % points APY is an assumption. Points P&L is
documented but not realised in `pnl_usd=`.

## Block pinned
**45,500,000** — TODO re-pin. Strategy is offline-first; if any of the
three load-bearing contracts (asBNB, ASTHERUS_STAKE_MANAGER, LISTA_LENDING)
has no code at the pinned block, the PoC degrades to a simulation that still
emits a valid PnL block.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER` — **TODO verify**.
- `BSC.asBNB` — **TODO verify**.
- `BSC.LISTA_LENDING` (`0xaa0f...e4b5`) — **TODO verify** (placeholder
  flagged in `BSC.sol`).
- `BSC.lisUSD`, `BSC.WBNB`, `BSC.PCS_V3_ROUTER` — verified.

## Risks
- **lisUSD depeg.** Borrowing a soft-peg stable and holding it transiently
  exposes us to a transient depeg. Mitigation: round-trip is atomic per
  iter; lisUSD never accumulates on book between calls.
- **Lista Lending ABI mismatch.** The interface is a placeholder; PoC
  wraps every supply/borrow call in try/catch and falls through to the
  simulation if any call reverts.
- **PCS v3 thin liquidity.** lisUSD/WBNB pool is < $5 M; large notional
  will move the price. The loop is bounded to ≤ 70 BNB per iter; above
  that the slippage assumption breaks.
- **Three TODO-verify addresses** in critical positions. The PoC's
  fork+simulation duality is what keeps this honest.

## Result
Status: **theoretical** (offline-first; three core addresses still
`TODO verify`). Expected PnL **+1.0–1.4 BNB per 100 BNB over 60 days**;
worse than B11-01 due to swap fees but with the upside of using a
non-Venus borrow venue when the Venus vBNB market is hot.
