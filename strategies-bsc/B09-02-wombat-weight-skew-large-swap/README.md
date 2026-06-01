# B09-02: Wombat asset-weight skew large-notional arb vs PCS StableSwap

## Mechanism
Wombat's invariant prices each marginal unit of a swap using the **coverage
ratio derivative** of the two tokens involved. Mathematically, the haircut on
`swap(in, out)` grows monotonically as `cov_in` increases past 1 and as
`cov_out` drops below 1. PCS StableSwap (Curve fork) uses a constant-amplification
invariant where marginal slippage is locally flat around the equal-balance
point and only blows up near the edge.

The interesting region for this strategy is the **knee** of the Wombat curve:
when one Wombat asset is already at `cov > 1.4` (e.g. operators dumped USDT into
the pool after a CEX deposit window), the *first* trader to swap that asset
*out* gets a quote that beats PCS by 15-40 bp on the marginal unit. But that
quote degrades quickly with size — Wombat actually becomes worse than PCS
beyond ~$500k. The arb is therefore size-aware:

1. Off-chain: read Wombat coverage ratios for USDT/USDC/BUSD/FDUSD.
2. Off-chain: binary-search the size `N*` where Wombat's marginal slippage on
   USDT->FDUSD equals PCS's quote.
3. On-chain: execute `Wombat.swap(USDT, FDUSD, N*)` and immediately
   `PCS.exchange(FDUSD, USDT, N*)` to round-trip back to USDT, harvesting the
   gap between Wombat's better-than-PCS quote (in the [0, N*] interval) and
   PCS's flat quote.

Unlike B09-01, this does **not** need a flash. The strategy uses pre-funded
USDT (treating the funder as a market-maker whose alpha is timing the size
correctly).

## Why it composes
- **Wombat marginal-haircut slope**: the asymmetric haircut formula
  `haircut = lambda * (cov_in - 1)^2` (informal) means at `cov=1.4` the marginal
  haircut on swap-out is *negative* up to a threshold. PCS has no equivalent
  mechanism.
- **PCS StableSwap as flat counterparty**: PCS's `get_dy(USDT, FDUSD, N)` is
  approximately linear in `N` for `N << pool D`, making it a clean reference.
- **Size optimization is the alpha**: any over-shoot pushes Wombat past its
  marginal-equal-PCS point and burns the spread on the tail of the trade.

## Preconditions
- Wombat Main Pool has FDUSD listed alongside USDT/USDC. // TODO verify (older
  versions of the Main Pool may only have BUSD; FDUSD might be in a sidecar
  pool).
- At the chosen block: `cov_USDT > 1.3` AND `cov_FDUSD < 1.0`.
- PCS StableSwap 3pool includes FDUSD (or use an FDUSD-paired pool index).
  **TODO verify** the canonical FDUSD/USDT/USDC PCS pool address.

## PnL math
Let:
- `q_W(N) = Wombat USDT->FDUSD output for N USDT in` (concave-down on the
  over-allocated USDT side).
- `q_P(N) = PCS FDUSD->USDT output for M FDUSD in` (effectively linear).

For correctly chosen `N*`:
- Wombat over-quotes by ~12 bp average across [0, N*] when `cov_USDT = 1.4`.
- PCS round-trip eats ~2 bp (1 bp each direction).
- Net: 10 bp on `N*`.

Concrete numbers at `N* = $250_000` (a typical break-even before Wombat curve
catches up):
- Wombat USDT->FDUSD out: ~250_300 FDUSD (12 bp bonus net of 5 bp haircut)
- PCS FDUSD->USDT out: ~250_275 USDT (1 bp PCS haircut)
- Net profit: ~$275 = 11 bp.

Realistic dislocations:
- `cov spread = 0.2`: 5-8 bp net -> $125-$200 per $250k.
- `cov spread = 0.4` (post-large LP withdrawal): 15-25 bp net -> $375-$625.
- `cov spread > 0.6` (rare, would require ~70% pool imbalance): 40+ bp.

## Block pinned
- `FORK_BLOCK = 45_700_000` (placeholder, ~Q3 2024). **TODO** verify a block
  where Wombat USDT coverage > 1.3 and FDUSD < 1.0.

## Risks
- **Size mis-estimation**: if `N` overshoots the knee, the tail of the swap
  loses the spread. PoC assumes the optimizer picks N correctly offline.
- **FDUSD reserve scarcity**: at high skew, Wombat's FDUSD `cash` may be too
  low to satisfy a large output; the swap will revert with insufficient cash.
  PoC sizes conservatively at 1/4 of FDUSD `liability`.
- **Concurrent liquidity changes**: a deposit/withdraw in the same block can
  reset `cov`. Mitigation: use a private RPC and gas-prioritize.
- **PCS pool indices**: TODO verify the exact PCS Stable pool that lists
  USDT+FDUSD; if FDUSD only sits in a 2pool with USDT, indices become (0,1).

## Result
- Status: **theoretical / offline-first**.
- Expected PnL: **+$100 to +$600 per $250k notional** at typical skew.
