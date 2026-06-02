# B03-08 — slisBNB → Lista mint lisUSD → Venus borrow BNB → recursive restake

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

In B03-02 the operator loops a single mechanism (Lista CDP) to build
synthetic BNB leverage. The bottleneck there is **Lista's own debt
ceiling and stability fee** — every additional round of slisBNB
collateral piles into the same `ilk.line` and pays the same fee.

A better leveraged-restaking stack uses **two independent debt
markets** in parallel:

- **Lista** underwrites lisUSD against bad-debt risk.
- **Venus** underwrites BNB against pool utilisation risk.

Because the two protocols' risk parameters are uncorrelated, the
operator can double-spend each unit of slisBNB collateral: lock it
once on Lista for lisUSD, then route the lisUSD into BNB and lock
that BNB on Venus for *more* BNB. The newly-borrowed BNB is restaked
through `LISTA_STAKE_MANAGER` to slisBNB and the round repeats.

## Mechanism stack

Each round (3 rounds total):

1. **Lista CDP** — deposit slisBNB, mint lisUSD at 75% LTV.
2. **PCS v3 swap** — lisUSD → WBNB (intermediate hop, 5 bp).
3. **Venus borrow** — deposit WBNB as collateral, borrow more WBNB at
   70% LTV. Withdraw to native BNB.
4. **Lista StakeManager** — restake the borrowed BNB to slisBNB.

The recursion converges geometrically because each round's Venus LTV
is applied to the diluted WBNB (which already lost ~$1 → $0.9982 at
the PCS hop).

## Why this is interesting

- **3-mechanism strategy** — Lista CDP, Venus BNB market, Lista
  StakeManager. Each is a distinct protocol with its own oracle, debt
  ceiling, and liquidation logic.
- **Double-using collateral**: unlike B03-02 (single-mechanism loop),
  the strategy harvests the slisBNB APR on the Lista-locked side
  while simultaneously running a Venus BNB loop — effectively
  collecting LST yield against two debt markets.
- **Liquidation independence**: a Lista clip auction does not trigger
  a Venus liquidation and vice versa. The two positions can be
  unwound independently.

## Address verification

- `BSC.slisBNB`, `BSC.lisUSD`, `BSC.WBNB`, `BSC.USDT` — verified.
- `BSC.LISTA_INTERACTION`, `BSC.LISTA_STAKE_MANAGER` — verified.
- `BSC.VENUS_COMPTROLLER`, `BSC.vBNB` — verified.
- `BSC.PCS_V3_FACTORY` / Router — verified.

## Status & PnL

- **Status:** offline-draft. All three mechanisms are simulated via
  balance accounting.
- **PnL model (3 rounds, $60k seed slisBNB, 30-day hold):**
    - Stacked slisBNB collateral after 3 rounds ≈ 100 + 75 + 56 + 42
      = 273 slisBNB ≈ $164k.
    - Intrinsic slisBNB APR: 3.2% × $164k × 30/365 = **+$432**
    - Lista borrow cost: 2.5% × $123k × 30/365 = **−$253**
    - Venus borrow cost: 3.5% × $86k × 30/365 = **−$248**
    - **Net ≈ −$69 / 30 days** in the modeled-base case.
  The strategy is **slightly negative carry at modeled APRs** but
  positive when slisBNB APR > 3.5% or Lista fee drops below 2%. The
  real edge here is **building leveraged BNB exposure** (delta
  ~2.7× the seed BNB notional) without going through a single
  protocol's debt ceiling.

## TODO

- Verify Lista WETH-ilk debt ceiling and stability fee values; the
  modeled `LISTA_BORROW_BPS=250` is from B03-02 and may need a fork
  read.
- Replace the PCS v3 lisUSD → WBNB hop with a Wombat hop if Wombat's
  lisUSD pool is deeper at the chosen block — saves ~3 bp per round.
- Add an explicit `IListaStakeManager.convertBnbToSnBnb` rate lookup
  so the round-3 slisBNB amount is realistic (currently 1:1).
- Cross-link with B01-01 (slisBNB Venus loop) — the Venus leg here is
  identical, only the source of the original collateral differs.
