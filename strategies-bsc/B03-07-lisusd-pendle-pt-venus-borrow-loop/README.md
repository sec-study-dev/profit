# B03-07 — lisUSD → Pendle PT lock + Venus secondary borrow

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

Pendle splits any yield-bearing token into **PT (principal)** and
**YT (yield)**. Holding PT alone gives a fixed-rate exposure: pay
`PT_price < $1` today, redeem `$1` at maturity. The implied yield is
`(1 − PT_price)/T`.

If a Pendle PT-lisUSD market exists with implied APY > Lista's
stability fee, the operator can **mint lisUSD against slisBNB via
Lista, immediately lock it into PT-lisUSD**, and skim the spread. The
PT itself can be **re-collateralised on Venus** (Venus isolated pools
list select Pendle PTs) to borrow USDT and recycle into a secondary PT
position — a 3-mechanism stack.

## Mechanism stack

1. **Lista CDP** — slisBNB collateral, mint lisUSD (stability fee ~2.5%).
2. **Pendle PT-lisUSD** — buy PT at a discount, redeem at par on
   maturity (fixed APY ~11% modeled).
3. **Venus borrow** — PT-lisUSD as collateral, borrow USDT (~4% APR),
   swap to lisUSD, buy more PT.

Hold to maturity (90 days). Net = PT yield × leveraged notional
− Lista stability fee − Venus borrow cost.

## Why this is interesting

- **3-mechanism strategy** — Lista CDP × Pendle PT × Venus borrow,
  spanning three independent protocols.
- **Locks in a fixed carry**: floating Lista stability fee is the only
  varying cost; PT yield is fixed by construction, Venus borrow APR
  changes slowly. This makes the trade close to delta-neutral and
  rate-neutral once entered.
- **Compoundable**: Pendle's secondary listing on Venus gives the only
  recycling path on BSC where the same lisUSD nominal can be
  re-deployed without going through an AMM, preserving the PT yield
  on the secondary loop too.

## Address verification

- `BSC.LISTA_INTERACTION`, `BSC.slisBNB`, `BSC.lisUSD`, `BSC.USDT` —
  verified.
- `BSC.PENDLE_ROUTER_V4` — verified.
- **PT-lisUSD market** — **TODO**: not yet listed. Pendle BSC currently
  ships PT-sUSDe and PT-slisBNB; PT-lisUSD requires a market listing.
  The strategy reduces to B04-01 / B04-02 patterns if no PT-lisUSD
  market exists; substitute PT-sUSDe and an extra lisUSD→USDe hop.
- **Venus vPT-lisUSD isolated market** — **TODO**: depends on Pendle
  market listing.

## Status & PnL

- **Status:** offline-draft, depends on PT-lisUSD market listing.
- **PnL model (90-day hold, $60k slisBNB collateral, $45k lisUSD
  borrow, secondary borrow ~$30k):**
    - Primary PT yield: 11% × $45k × 90/365 = **+$1,221**
    - Secondary PT yield: 11% × $30k × 90/365 = **+$813**
    - Lista stability: 2.5% × $45k × 90/365 = **−$277**
    - Venus borrow: 4% × $30k × 90/365 = **−$296**
    - **Net ≈ +$1,461 / 90 days ≈ 13.2% annualised on $45k initial debt.**

## TODO

- Verify Pendle PT-lisUSD market listing on BSC. If absent, swap the
  middle mechanism for PT-sUSDe and add a lisUSD → USDe hop (drops
  this to a B05 cross-stable variant).
- Resolve Venus isolated-pool address for vPT-lisUSD.
- Add a maturity-rolling variant: at expiry, redeem PT, repay Venus,
  re-mint into the next-quarter PT.
- Cross-link with B04 family (PT-cash-carry parents) — they share the
  Pendle leg but use sUSDe / slisBNB as the underlying.
