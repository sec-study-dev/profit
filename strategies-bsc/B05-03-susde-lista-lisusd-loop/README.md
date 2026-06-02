# B05-03: sUSDe → Lista lending → borrow lisUSD → swap USDe → re-stake loop

## Mechanism
Same sUSDe-carry shape as B05-01 but routed through **Lista Lending +
lisUSD** instead of Venus + USDT. The two markets price risk differently,
so the *spread between Lista's lisUSD borrow APR and Venus' USDT borrow
APR* is the alpha. B05-01 picks the strictly cheaper leg on most days;
this strategy picks Lista when (a) Lista's lisUSD borrow APR is lower, or
(b) Lista's LTV on sUSDe is higher, or (c) we want to take a *short*
lisUSD position to hedge a B03-style lisUSD long.

1. **Ethena sUSDe (ERC-4626)** — same as B05-01.
2. **Lista Lending isolated pool** — Lista lists sUSDe (and USDe directly)
   as collateral assets. Borrow asset of interest is **lisUSD**, the
   Lista-native CDP-issued stable. lisUSD borrow APR is set by a kink-IRM
   parameterised differently from Venus' USDT — usually 50-150 bps lower
   during periods when the Lista Stability Module has slack.
3. **PCS StableSwap / Wombat lisUSD/USDe** — borrowed lisUSD swaps to USDe
   on PCS StableSwap (lisUSD-USDT-USDe 3-pool) or Wombat. The lisUSD-USDe
   path is typically 5-15 bp tight depending on Wombat coverage.

## Why it composes (vs B05-01)
- **lisUSD borrow APR is structurally lower** than vUSDT when Lista's
  PSM is open and absorbing redemptions — Lista wants borrow demand to
  recycle PSM USDT inflows back as new lisUSD supply, and tunes IRM
  cheap. B05-01 vs B05-03 share legs but capture *different* spreads.
- **Lista accepts sUSDe at a higher LTV (~ 82 %)** than Venus typically
  does (~ 78 %), enabling 1-step-deeper recursion: with 4 loops, leverage
  goes from ~3.0× (Venus path) to ~4.0× (Lista path).
- **Risk is genuinely different**: Lista lending uses its own oracle
  stack and its own liquidation engine (`liquidationCall` style). A
  Venus governance change does not affect this position.

## Preconditions
- Lista Lending has sUSDe collateral listed and lisUSD borrowable at the
  pinned block.
- `(lisUSD borrow APR) + (lisUSD → USDe swap cost amortised) <
  (sUSDe APY)` — i.e. the carry is positive.
- PCS StableSwap (or Wombat) lisUSD-USDe liquidity > $2M so the per-loop
  swap stays under 20 bp slippage.

## Strategy steps (4 iterations, 100k USDe principal)
1. Deposit 100 k USDe into sUSDe.
2. Iteration 1:
   - `IListaLending.supply(sUSDe, balance, address(this))`.
   - `IListaLending.borrow(lisUSD, amount, address(this))` with
     `amount = collateral_usd * 0.82 * 0.95`.
   - Swap `lisUSD → USDe` via PCS StableSwap (or Wombat fallback).
   - Re-stake USDe → sUSDe.
3. Repeat for N=4.

Per-step LTV = 0.82 × 0.95 = 0.779. Leverage at N=4:
1 + 0.779 + 0.607 + 0.473 + 0.368 ≈ **3.23×**.

## PnL math (100 k USDe principal, 30-day horizon)
Indicative rates:
- sUSDe APY: 9.0 %.
- Lista lisUSD borrow APR: 4.0 % (vs vUSDT 5.5 % in B05-01).
- Per-loop swap cost: 15 bp (PCS StableSwap fee + small Wombat-coverage
  haircut on the lisUSD → USDe leg).
- Levered: 3.23× collateral, 2.23× debt.
- Gross APY: 3.23 × 9.0 − 2.23 × 4.0 = 29.07 − 8.92 = **+20.15 %**.
- Swap drag: 15 bp × 2.23 × 4 loops / 1 year amortised ≈ 0.55 % drag /
  year (loops are one-time but treated as annualised drag here).
- **Net APY ≈ +19.6 %**, 30-day yield ≈ +1.61 % ≈ **+1,610 USD per 100 k
  USDe**.

Gas: ~1.8M (Lista supply+borrow is ~250k per loop, swap ~120k). At 1
gwei × $600/BNB ≈ $1.08.

## Block pinned
**42_500_000** — same as B05-01 for fair comparison; lisUSD IRM and
Lista's sUSDe listing both expected operational by then. // TODO verify
once Lista Lending publishes canonical sUSDe market address.

## Addresses used
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe (`BSC.USDe`).
- `0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2` — sUSDe (`BSC.sUSDe`).
- `0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5` — lisUSD (`BSC.lisUSD`).
- `0xaA0F8c41E3DC22a8C4d4Da6da1A1cAF048D7e4b5` — Lista Lending
  (`BSC.LISTA_LENDING`). // TODO verify — currently a placeholder in
  `BSC.sol`.
- `0xeC2D6Da16e9aDe97c6da8ad6E8C5e6dD7e9d4e8e` — PCS StableSwap router
  (`BSC.PCS_STABLE_ROUTER`). // TODO verify.
- `LOCAL_PCS_STABLE_LISUSD_USDE` — PCS StableSwap lisUSD/USDe pool.
  Placeholder `0x000000000000000000000000000000000000B533`.

## Risks
- **Lista oracle de-peg trigger**: if Lista's sUSDe oracle marks down
  during a USDe wobble, liquidation hits faster than Venus would (Lista
  uses a tighter LT / LTV gap). Keep 7 % buffer.
- **lisUSD soft-liquidation drag**: lisUSD's soft-liquidation mechanism
  doesn't apply to non-CDP borrows but does affect lisUSD price (B03 is
  the dedicated lisUSD-mechanism family). A lisUSD redemption shock can
  briefly spike lisUSD up to $1.01-$1.02, raising debt USD value 1-2 %.
- **Lista borrow cap**: Lista applies per-asset supply / borrow caps that
  can prevent full N=4 recursion if our position is large.
- **PCS StableSwap depth**: lisUSD-USDe leg is thinner than the
  USDT/USDe pool used in B05-01; size guard at $20k per swap iteration.

## Result
Status: **theoretical**. Expected PnL: **+1.4 – 1.9 % over 30 days on
100 k USDe principal**, slightly better than B05-01 because (a) Lista's
lisUSD APR is structurally cheaper and (b) sUSDe LTV is higher. Worse on
the liquidation-buffer dimension — this is a higher-vol variant of the
same trade.
