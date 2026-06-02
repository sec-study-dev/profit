# B10-03 — 5-stable peg-surface scan + triangular atomic arb

## Family

B10 · Cross-stablecoin CDP basis (surface-scan branch).

## Thesis

BSC has at least **eight** "$1" stables in active trading: USDT, USDC, BUSD
(legacy), FDUSD, USD1, lisUSD, USDe, VAI. Five of them — `lisUSD`, `FDUSD`,
`USDe`, `USDT`, `USDC` — have **simultaneously deep PCS v3 / v2 / Wombat
pools**, so cross-quote prices form a **graph** where every node is a
stablecoin and every edge is a directed swap price.

If the graph is *not* arbitrage-free, there exists a closed triangle
`A → B → C → A` where the product of the three swap prices exceeds 1 (after
fees). The strategy:

1. Polls all `5 × 4 = 20` directed quote edges (the diagonal `A → A` is
   trivially 1).
2. Computes, for every triangle, the round-trip product and the round-trip
   fee.
3. Triggers an atomic 3-leg swap on the first triangle whose
   `product − fees > MIN_PROFIT_BPS`.

This is materially different from a generic stable arb because:

- Triangles passing through **CDP-class** legs (`lisUSD`, `USDe`,
  `VAI`-extensions) tend to dislocate during BNB drawdowns when CDP holders
  panic-sell their freshly-minted debt.
- Triangles passing through **issuance-asymmetric** legs (USD1, FDUSD when
  Binance reserve-attestation gets delayed) dislocate during issuance
  pauses.

The same scanner picks up both regimes. Different B10 angles unify under
the same code path.

## Mechanism stack

1. **Off-chain (or `view`-only) edge quote** — for each pair `(A, B)` in the
   5-stable basket, read both PCS v3 quote (preferred fee tier) and Wombat
   quote, keep the better one. Edges are stored as 1e18-scaled prices in a
   `mapping(address => mapping(address => uint256))`.
2. **Triangle enumeration** — `C(5,3) × 2 = 20` directed triangles. For
   each, compute `p_AB × p_BC × p_CA` and the cumulative fee
   `f_AB + f_BC + f_CA`.
3. **Threshold gate** — if `(product - 1e18) > FEE_BUDGET + MIN_PROFIT`,
   queue the triangle for execution.
4. **Atomic execution** — `swap A → B → C → A` via the appropriate routers.
   The trader funds the first leg; the cycle returns to A with surplus.

We rely on the *spot* swap surface — no flash needed because the trader
already holds USDT/USDC. This makes the strategy gas-light and
parallelisable across triangles.

## Why this is a real "B10" play (not B07 / B09)

B07 (PCS v3 cross-DEX) scans pairs, not triangles, and ignores the
CDP/issuance asymmetry between stables. B09 (Wombat dynamic-weight) only
looks at one DEX. B10-03 is the first strategy that treats the **5-stable
quote graph** as the unit of analysis — the alpha is in the topology of the
graph, not in any individual edge.

## Example triangle: `USDT → lisUSD → USDe → USDT`

- `USDT → lisUSD` on PCS v3 stable pool: 1.0030 (lisUSD bid below par
  because CDP holders unload).
- `lisUSD → USDe` on Wombat (both held as "yield stables"): 0.9985
  (USDe shorter supply, light premium).
- `USDe → USDT` on PCS v2: 1.0010 (USDe slightly rich on retail wallet
  side).
- Product: `1.0030 × 0.9985 × 1.0010 = 1.00250`.
- Fees: 1 bp (PCS v3) + 5 bp (Wombat) + 25 bp (PCS v2 generic) = 31 bp.
- Net: `25.0 bp − 31 bp = -6 bp`. Triangle skipped.

But during a BNB drawdown the lisUSD edge prints 60 bp discount instead of
30 bp, and the triangle clears at `+24 bp` net. The scanner picks this up
on the next block.

## Address verification

- All 5 token addresses verified against `BSC.sol`.
- Pool addresses resolved at runtime via PCS v3 factory + Wombat main pool;
  pool absences are gracefully skipped.

## Status & PnL

- **Status:** offline-first. Triangle scanner runs against a synthetic 20-edge
  price matrix (defined in the test) to exercise the triangle-enumeration
  logic and verify that the printed atomic PnL matches the modelled
  triangle.
- **PnL model:** at any given hour, on average 1 of 20 triangles clears
  `+15 bp`. With a $500k notional per atomic execution, that is **$750 per
  triangle**, repeatable ~30× per week ⇒ **~$22.5k / week**.

## TODO

- Pin a fork block where one specific triangle is verifiably open and run
  the on-fork test against real router quotes.
- Add Wombat quote-side: currently the offline test only models a single
  AMM family per edge.
- Extend basket to 6 stables (add VAI or USD1) once on-chain liquidity is
  confirmed > $100k per direct pair.
- Add a **negative-result guard**: if the scanner finds no profitable
  triangle for `N` consecutive scans, back off scan frequency.
