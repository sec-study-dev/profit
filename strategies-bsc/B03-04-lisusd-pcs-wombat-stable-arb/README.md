# B03-04 — lisUSD cross-venue StableSwap arb (PCS v3 ↔ Wombat)

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

`lisUSD` trades on at least two venues with different curve dynamics:

- **PCS v3 lisUSD/USDT** — a concentrated-liquidity pool. Wide tick
  spacing around peg; **price discovery is fast**, so PCS v3 reacts to
  arrivals first.
- **Wombat lisUSD-LP / USDT-LP** — Wombat's dynamic-coverage StableSwap
  ratio shifts as one side's coverage drifts. Wombat lags on price
  reversion because of its haircut mechanism.

When PCS v3 reprices lisUSD (e.g. a sudden mint dumps lisUSD to $0.997),
Wombat's `lisUSD-LP` ratio is briefly stale at the old price (say
$0.999). The two-venue **basis** is harvestable atomically: flash USDT,
buy cheap lisUSD on PCS v3, sell expensive lisUSD on Wombat, repay flash.

This is a **pure intra-stable-stable basis arb on the same chain across
two AMM families** — distinct from B03-01 (depeg-vs-par) because both
venues independently quote lisUSD; we're not relying on any out-of-band
mechanism (no CDP payback). It is the most "boring" of the family and
the most reliable.

## Mechanism stack

1. **PCS v3 flash** USDT from `USDT/USDC` 1bp pool.
2. **PCS v3 swap** USDT → lisUSD at the lower price.
3. **Wombat swap** lisUSD → USDT at the higher price.
4. **Repay** the flash from the USDT output.

Net PnL ≈ `(Wombat_price − PCS_price) × notional − PCS_flash_fee − two
swap fees`.

## Why this is interesting

- **Two AMM families on the same chain**: PCS v3 is a Uniswap-V3 fork
  (CLAMM), Wombat is an asymptote-bonded StableSwap. Their re-pricing
  speeds differ structurally, not just because of different LP behaviour
  — so the basis is a function of *mechanism design*, not LP cost.
- **No CDP exposure required**: we never touch Lista's Interaction. Pure
  atomic AMM arb backed by the depeg of one venue against another.
- **Tightest fee budget in family B03**: 1 bp flash + 1 bp PCS + ~4 bp
  Wombat haircut = 6 bp budget. Any basis above ~6 bp is harvestable.

## Address verification

- `BSC.PCS_V3_FACTORY = 0x0BFbCF...1865` — verified.
- `BSC.WOMBAT_ROUTER = 0x196098...4aDD7` — **TODO verify**.
- `BSC.WOMBAT_MAIN_POOL = 0x312Bc7...55fb0` — **TODO verify**. Likely
  the Lista lisUSD pool is in a separate Wombat side-pool, not the main
  pool — need to confirm pool address against Wombat's pool registry.
- `BSC.lisUSD` / `BSC.USDT` — verified.

## Status & PnL

- **Status:** offline-draft. The Wombat pool address used for the
  lisUSD-LP / USDT-LP swap is the main pool placeholder; in live runs
  this should be replaced with the dedicated Lista-Wombat side-pool.
- **PnL model:** at 10 bp basis on a $1m notional, the strategy nets
  `10 − 6 = 4 bp = $400 per opportunity`. Modeled as such in the PoC.

## TODO

- Validate Wombat's lisUSD pool address (`WOMBAT_LISTA_POOL`); the main
  pool may not include lisUSD.
- Cross-verify the IWombatPool `quotePotentialSwap` signature against
  the deployed contract — Wombat has shipped multiple ABIs.
- Add a Thena Stable Pair leg (lisUSD/USDT on Thena's solidly-style
  pool) for triangular variants.
