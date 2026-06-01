# B15-05 — Lista lisUSD CDP · Wombat · PCS StableSwap cross-stable basis

## Family

B15 · 三协议机制堆叠. A *pure-stable* basis carry: mint lisUSD against
slisBNB, run it across two structurally different StableSwap venues, and
repay — capturing the cross-venue depeg basis plus the lisUSD funding
spread, while the slisBNB collateral keeps earning native yield.

## Thesis

BSC has two major dollar StableSwap venues with **different invariants**:

- **Wombat** runs a *dynamic-asset-weight* invariant. lisUSD vs USDT
  pricing reflects asymmetric pool balance + coverage ratio.
- **PCS StableSwap** runs the *classic Curve-style invariant*. USDT vs
  USDC pricing reflects symmetric depth.

Differences in haircut + curvature between Wombat and PCS create a
persistent ~5–20 bp basis on lisUSD/USDT. The strategy:

1. **Mint** lisUSD by depositing slisBNB into Lista CDP. The slisBNB
   collateral keeps earning native staking yield (3.2 % APR).
2. **Swap lisUSD → USDC** on Wombat (typically the cheaper hop because
   Wombat over-weights lisUSD when the Lista treasury seeds liquidity).
3. **Swap USDC → USDT** on PCS StableSwap (Curve-shape, deep USDC/USDT
   leg).
4. **Recycle USDT → lisUSD** on Wombat or PCS — whichever is cheaper at
   the block — to repay/reduce the CDP debt and capture the basis.

When the chain of hops returns *more* lisUSD than was minted, the carry
is the basis profit; the slisBNB carries the residual.

## Why it composes — the 3 mechanisms

1. **Lista CDP `Interaction.deposit + borrow`** — only BSC route to mint
   a *fresh* dollar against a yielding LST collateral. Without it, the
   strategy is just an AMM-vs-AMM swap (B07/B09 territory).
2. **Wombat StableSwap dynamic-weight pool** — only protocol on BSC
   exposing the asymmetric (lisUSD-side over-weighted) curve. The
   coverage-ratio invariant makes the lisUSD↔USDC hop cheaper when
   lisUSD's asset is over-supplied.
3. **PCS StableSwap (Curve-style invariant)** — closes the loop on the
   USDC↔USDT leg. Curve's symmetric curvature gives a different price
   from Wombat, exposing the cross-venue basis.

**No 2-mechanism subset works:**
- (Lista + Wombat) alone is a 1-hop CDP swap — captures only one curve's
  spread.
- (Lista + PCS) alone misses the asymmetric lisUSD venue — most depeg
  arb sits in Wombat's coverage-ratio curve.
- (Wombat + PCS) alone is a pure StableSwap cross-arb (B07/B09 territory)
  — no balance-sheet leverage, no slisBNB carry.

The triple uniquely captures the *cross-invariant basis* **and**
keeps the slisBNB collateral earning staking yield throughout the loop.

## Preconditions

- Lista lisUSD CDP open for slisBNB at the fork block.
- Wombat lisUSD/USDC pool live with non-trivial depth.
- PCS StableSwap USDC/USDT pool live.

## Strategy steps (PoC)

1. Seed: `100 slisBNB` (~$60 k @ $600/BNB).
2. `IListaInteraction.deposit(slisBNB, 100e18)` and
   `borrow(slisBNB, 30 000e18)` — 50 % LTV target lisUSD mint.
3. `IWombatPool.swap(lisUSD → USDC, 30 000e18)` — at a typical
   Wombat lisUSD-over-supplied curve, exiting lisUSD pays ~3 bp.
4. `IPancakeStableRouter.exchange(USDC → USDT, dy)` — Curve-shape, ~2 bp
   haircut.
5. Cross-curve repay: `IWombatPool.swap(USDT → lisUSD, dy)` — re-enters
   lisUSD at a *cheaper* implied rate when the pool's lisUSD-asset is
   over-supplied. Captures ~5–15 bp net.
6. `IListaInteraction.payback(slisBNB, recovered lisUSD)`.
7. Hold the residual slisBNB position; closed-form carry projection.

## PnL math

100 slisBNB ≈ $60 000. lisUSD borrow 30 000 at 50 % LTV.

Per-round basis (single hop sequence):
- Wombat lisUSD→USDC haircut: −3 bp on 30 000 = **−$9**
- PCS USDC→USDT haircut: −2 bp on 30 000 = **−$6**
- Wombat USDT→lisUSD: +15 bp on 30 000 = **+$45**
- **Net per round: +$30** ≈ 10 bp on principal.

Per-day at 1 round/day for 30 d: **+$900**.
Plus slisBNB native carry: 60 000 × 0.032 × 30/365 = **+$157**.
Minus lisUSD stability fee: 30 000 × 0.02 × 30/365 = **−$49**.

**Net: ≈ +$1 008 / 30 d / $60 k = ~20 % combined APR.**

## Block pinned

`FORK_BLOCK = 42_550_000`. Re-pin when fork RPC is available and the
exact pool indices for PCS StableSwap are confirmed at runtime.

## Addresses used

- `BSC.slisBNB`, `BSC.LISTA_INTERACTION`, `BSC.lisUSD`.
- `BSC.WOMBAT_MAIN_POOL`, `BSC.WOMBAT_ROUTER`, `BSC.USDC`, `BSC.USDT`.
- `BSC.PCS_STABLE_ROUTER`.

## Risks

- **Basis flip**: if Wombat re-weights, the lisUSD↔USDC haircut can flip
  positive (cost rather than benefit). PoC budgets a `MIN_NET_BPS`
  guardrail — reverts if the round-trip basis falls below threshold.
- **lisUSD depeg**: a sustained lisUSD depeg would price-impact the
  recovery hop. Mitigation: small per-round notional + frequent rounds.
- **Lista liquidation**: 50 % LTV target buffers ~30 % below the
  ~80 % liquidation threshold; a flash slisBNB depeg still risks the
  vault.

## Result

Status: **offline-draft**. Expected PnL: **+$1 000 / 30 d / $60 k equity
(~20 % combined APR)** combining cross-curve basis capture (60 % of the
yield) and slisBNB native staking (15 % of the yield) less the lisUSD
funding fee.

## TODO

- Confirm PCS StableSwap (USDC, USDT) pool indices at the fork block.
- Confirm Wombat lisUSD asset exists in the main pool (otherwise switch
  to the `LISTA_USDT_POOL` if separately deployed).
- Tighten the `MIN_NET_BPS` guard once live data is available.
