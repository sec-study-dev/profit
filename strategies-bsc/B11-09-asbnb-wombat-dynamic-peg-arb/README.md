# B11-09: asBNB peg arb via Wombat dynamic-asset-weight pool

## Mechanism
Companion arb to B11-04 (PCS v3 constant-product peg arb), routed through
a Wombat StableSwap pool instead. Wombat uses a **dynamic asset-weight
invariant** that prices each side based on the running weight imbalance —
when one token is overweight (deposit pressure), the *other* token trades
at a predictable premium that decays as users arbitrage.

For asBNB:
1. **Internal rate** — `asBNB.convertToAssets(1e18)` from the Astherus
   StakeManager; drifts up monotonically with validator yield.
2. **Wombat pool rate** — quoted via `quotePotentialSwap`. When the pool
   accumulates excess WBNB (a wave of asBNB→WBNB sells leaves the pool
   short on asBNB), the implicit ask for asBNB rises above peg.

Premium-side atomic arb:
- BNB → mint asBNB at internal (cheap) rate.
- Swap asBNB → WBNB on Wombat at the pool's premium.
- Profit = pool premium − Wombat haircut − unwind dust.

No flash loan needed because Wombat's haircut at small sizes (~5 bp) is
well below the typical PCS v3 flash fee (25 bp). The trade-off is
inventory risk: we hold ~50 BNB for one block instead of a 5 BNB flash
buffer.

The discount-side route (asBNB cheap in pool) is **not atomically
arbable** because Astherus's redemption queue is asynchronous (7-15 d).
A positional discount-trade is documented but not implemented here.

## Why it composes
- Wombat pools use **asset coverage ratios** to price swaps; an unbalanced
  pool gives a deterministic premium until the imbalance closes. This is
  a *different* pricing model from PCS v3 (constant product), so the
  arb opportunities arise at different times and rarely collide.
- Astherus StakeManager is the cheap mint side, identical to B11-04.
- The "no-flash" route is simpler (no callback, fewer gas) and works
  when the premium is just barely above the PCS flash fee — these are
  the most frequent dislocations.

## Preconditions
- `BSC.asBNB`, `BSC.ASTHERUS_STAKE_MANAGER` live.
- Wombat asBNB/WBNB pool (or BNB-cluster pool that whitelists asBNB) live
  with ≥ $5 M TVL.
- Pool quotes asBNB above internal rate by ≥ 120 bp (covers haircut +
  margin + gas).

## Strategy steps
1. Start with 50 BNB native trading inventory.
2. `ASTHERUS_STAKE_MANAGER.deposit{value: 50}()` → ~48.78 asBNB.
3. `WOMBAT_POOL.quotePotentialSwap(asBNB, WBNB, 48.78e18)` → check
   `quoteOut > 50 BNB × 1.012` (1.2 % cover for haircut + dust).
4. If quote insufficient → bail without swapping (no trade).
5. Else `WOMBAT_POOL.swap(asBNB, WBNB, 48.78, minOut, self, deadline)`
   → ~50.94 WBNB out.
6. `WBNB.withdraw(50.94)` → native BNB for clean PnL measurement.
7. Emit standard PnL block.

## PnL math
At pinned block 45,500,000, modelled dislocation:
- Pool quote: 1.045 BNB / asBNB (200 bp gross premium)
- Internal rate: 1.025 BNB / asBNB
- Wombat haircut (small size, aligned pool): ~5 bp
- Gross spread: 2.00 % − 0.05 % haircut = 1.95 %
- Conservative net: **+0.94 BNB on 50 BNB notional ≈ +1.88 %** atomic
- At $600/BNB → **~+$564 per executed instance**

Gas: ~250 k for deposit + swap + unwrap ≈ $0.15 at 1 gwei. Negligible.

### Comparison to B11-04
| Metric | B11-04 (PCS v3 flash) | B11-09 (Wombat positional) |
|---|---|---|
| Capital at risk | ~5 BNB (flash buffer) | 50 BNB (inventory) |
| Atomic % return | ~1.70 % | ~1.88 % |
| Min profitable spread | 30 bp | 120 bp (haircut + dust) |
| Flash callback complexity | Yes | No |
| Pool model | constant product (UniV3) | dynamic asset-weight |

B11-04 is better when spreads are tight (30-60 bp). B11-09 is better when
spreads are wide and the operator prefers inventory over flash mechanics,
or when Wombat dislocates while PCS v3 doesn't.

## Block pinned
**45,500,000** — TODO re-pin once Wombat lists asBNB. Offline-first; the
PoC bails cleanly without swapping if the quote doesn't clear the
breakeven threshold.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.asBNB` — **TODO verify**.
- `LOCAL_WOMBAT_POOL_ASBNB` — placeholder pending Wombat pool listing.
- `BSC.WBNB` — verified.

## Risks
- **Pool depth**. Wombat's asymmetric invariant means large trades self-
  correct the premium aggressively. PoC bounds size to 50 BNB; sizing
  above 5 % of pool TVL collapses the spread.
- **Inventory risk**. Unlike B11-04, this strategy holds 50 BNB worth of
  asBNB for one block. A bad block ordering (sandwich) could front-run
  the swap and eat the spread. Mitigation: route via 48 Club / Blockrazor
  private bundle.
- **TODO-verify addresses**. PoC gates every external call with
  `_hasCode` + try/catch.
- **StakeManager pause**. If Astherus pauses `deposit()` between BNB→asBNB
  and pool swap, we have asBNB inventory + no peg-anchor. Acceptable
  because the StakeManager is the cheap-mint side; pause only blocks new
  mints, doesn't affect existing balances.

## Result
Status: **theoretical** (offline-first; Astherus + Wombat asBNB pool both
TODO verify). Expected PnL per executed instance: **~+0.94 BNB ≈ +$564
atomic** at modelled 200 bp Wombat dislocation; trade auto-bails below
120 bp to avoid haircut-driven loss.
