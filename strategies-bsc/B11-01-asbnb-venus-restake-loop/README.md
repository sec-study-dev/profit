# B11-01: asBNB → Venus → borrow BNB → Astherus re-stake loop

## Mechanism
Three-protocol stack that mirrors B01-01 but swaps slisBNB for Astherus asBNB
so the position earns Astherus "restake" / AVS rewards on top of the levered
BNB validator yield.

1. **Astherus asBNB** — BNB restake LST. ERC-20, exchange rate read via the
   ERC-4626-style `convertToAssets`. Mint via the Astherus StakeManager,
   redeem through a delayed-withdraw queue (asymmetric exit).
2. **Venus Core / Isolated pool** — Compound v2 fork. The relevant market is
   `vasBNB` (Venus must list asBNB as collateral; this is the load-bearing
   "TODO verify" — the placeholder `LOCAL_VASBNB` falls through to the
   offline path when no code is present).
3. **vBNB borrow leg** — borrow native BNB against the asBNB collateral and
   recycle into the StakeManager. Stops when liquidity dips below the
   `SAFETY_BPS` haircut.

## Why it composes
- asBNB is a plain ERC-20, so all the same Venus / Compound v2 plumbing that
  works for slisBNB works here without a custom adapter.
- The yield stack is **strictly additive vs. B01-01**:
  - underlying BNB validator APY → priced into the asBNB exchange rate
  - Astherus AVS / restake APY → either accrues to the same exchange rate
    *or* is paid in `$AST` tokens / "Astherus points"
  - vBNB borrow APR is the only cost, identical to B01-01
  So the carry is `L × (LST APY + points APY) − (L − 1) × vBNB APR`, where
  `L` is the on-chain leverage multiple.
- The recursive structure is *identical* to B01-01, which makes it cheap to
  re-pin and reason about — only the LST token changes.

## Preconditions
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER` and `LOCAL_VASBNB` all have code
  at the pinned block.
- Astherus StakeManager exposes either `deposit() payable` or `stake()
  payable`; we try both to absorb the unverified-ABI risk.
- Venus has listed asBNB as a collateral asset (CF > 0). Today this is
  speculative — Venus governance has not (publicly) onboarded asBNB at the
  time of writing.

## Strategy steps
1. Start with 100 BNB principal as native BNB.
2. `Comptroller.enterMarkets([vasBNB, vBNB])`.
3. Iteration i ∈ [0, 4):
   - `ASTHERUS_STAKE_MANAGER.deposit{value: bnb_bal}()`
   - `vasBNB.mint(asBNB_bal)`
   - read `getAccountLiquidity`, borrow 95 % of it as BNB via `vBNB.borrow`.
4. Final-iteration drip: any leftover BNB → stake → supply.
5. Hold 60 days (`vm.warp`). Refresh `vBNB.borrowBalanceCurrent` and
   `vasBNB.balanceOfUnderlying` to materialise interest. Refresh asBNB
   oracle override from `convertToAssets(1e18)`.
6. Emit standard `pnl_usd= / gas_usd= / net_usd=` block.

## PnL math
Indicative rates at block 45,500,000 (refine on-chain):
- asBNB BNB-stake APY: ~3.8 %
- Astherus points APY (USD-equiv, **assumption**): ~1.0 %
- vBNB borrow APR: ~2.4 %
- Venus asBNB CF: 0.65 (conservative; Lista slisBNB sits at 0.70 today)
- Effective leverage from 4 iters at 0.6175 step LTV: **2.379×**
- Net APR = `2.379 × (3.8 + 1.0) − 1.379 × 2.4 = 11.42 − 3.31 = +8.11 %`
- 60-day yield = `8.11 × 60/365` ≈ **+1.33 % on principal ≈ +1.33 BNB**
- Per 100 BNB principal ≈ **+800 USD** at $600/BNB.
- Gas: ~5 enterMarket/mint/borrow cycles + 1 deposit per loop ≈ 1.5 M gas
  ≈ $0.90 (negligible).

### Points valuation caveat
The 1.00 % `POINTS_APY_BPS` is a **stand-in for an unknown Astherus point ↔
USD ratio**. If points turn out worthless the net APR drops to ~5.7 %; if
they realise at ezETH-tier valuations (~3 % USD/yr) the net jumps to
~10.5 %. The PoC tracks asBNB at its BNB-denominated exchange rate only —
**points P&L is documented, not realised** in the printed `pnl_usd=`.

## Block pinned
**45,500,000** — TODO re-pin once Astherus is confirmed live and indexed by
BscScan at a reachable block. The PoC is fork-aware and degrades to an
offline simulation when either `BSC_RPC_URL` is unset or any of the three
load-bearing addresses has no code at the pinned block.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER` (`0xb0fd...0a1`) — **TODO verify** (flagged in
  `src/constants/BSC.sol`). PoC gracefully handles a missing/unimplemented
  ABI via try/catch on both `deposit()` and `stake()`.
- `BSC.asBNB` (`0x7773...12b6`) — **TODO verify** (flagged in `BSC.sol`).
- `LOCAL_VASBNB` (`0x...beef` placeholder) — Venus vasBNB market. Not in
  `BSC.sol` yet; pinned inline pending the Venus market listing.
- `BSC.VENUS_COMPTROLLER`, `BSC.vBNB` — verified.

## Risks
- **Address-validity risk.** asBNB / ASTHERUS_STAKE_MANAGER both still
  `TODO verify` in `BSC.sol`. Mitigation: PoC `_hasCode` gate + try/catch
  on both `deposit()` and `stake()`; offline path emits the same PnL block.
- **asBNB de-peg.** New LST, thin secondary liquidity. A 1 % oracle vs
  market drift can push the position toward Venus liquidation despite the
  95 % haircut.
- **Astherus withdrawal queue.** Like slisBNB, redemption is asynchronous.
  Emergency exit via PCS slisBNB/asBNB swap will burn ~0.3-0.5 % slippage.
- **Points valuation.** The 1 % APY is an assumption, not a market price.
- **Venus governance.** asBNB CF and the IRM are mutable; a CF cut → forced
  partial unwind.

## Result
Status: **theoretical** (offline-first; both asBNB and ASTHERUS_STAKE_MANAGER
addresses still flagged `TODO verify`). Expected PnL: **+1.0–1.7 BNB per 100
BNB over 60 days**, dominated by the levered stake/borrow spread and
*assuming* a 1 % points APY. With points valued at zero the strategy is
still net +0.6 BNB; with ezETH-tier points it nudges +2.5 BNB.
