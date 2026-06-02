# B10-07 — lisUSD + Pendle PT-lisUSD + Venus borrow loop

## Family

B10 · Cross-stablecoin CDP basis (term-structure / fixed-yield branch).

## Thesis

Pendle's PT-lisUSD price encodes a *fixed* yield-to-maturity (the
discount). Venus' USDT borrow rate, by contrast, is a *floating* IRM-based
rate that is usually well below the PT discount when:

- the lisUSD-side yield (Pendle's `discount = PT_yield`) is bid up by
  rewards farmers (Pendle MerkleDistributor, Lista incentives), AND
- Venus USDT supply is still cheap because of broader Venus
  utilization < kink.

A user holding lisUSD can therefore:

1. Swap lisUSD → PT-lisUSD at the Pendle market (locks in `PT_implied` to
   maturity).
2. Use a fraction of the PT as collateral (via a Venus isolated market or
   a Lista-style direct accept) to borrow USDT.
3. Park the borrowed USDT in a lisUSD-supply sink (Lista MasterChef,
   Venus VAI vault, or a PCS Stable LP) to earn an extra `supply_yield`
   margin.
4. At maturity, PT redeems 1 lisUSD ⇒ unwind the borrow, withdraw the
   sink, net.

This is the BSC-native analogue of mainnet F07-07
(`pt-susde-aave-borrow-loop`), with three substitutions: PT-lisUSD instead
of PT-sUSDe, Venus instead of Aave, and Lista's CDP / PCS as the close-out
venue instead of Maker / Curve.

## Mechanism stack (3 distinct mechanisms)

1. **Pendle PT** — `swapExactTokenForPt(lisUSD → PT-lisUSD)`. Locks the
   discount and removes the position from the floating-rate side of the
   market.
2. **Venus borrow** — supply (lisUSD or PT-as-collateral) into a Venus
   isolated market, `enterMarkets()`, and borrow USDT against it at the
   IRM-priced rate.
3. **PCS Stable / Lista sink** — `USDT → lisUSD` close hop on PCS Stable
   so the borrowed USDT can be parked back on the same side that's
   earning `LISUSD_SUPPLY_BPS`. The Lista CDP can be re-used as the sink
   if its MasterChef rate is higher.

## Why this is genuinely B10 (and not B04 / B05)

- B04 (PT cash-carry) is *purely* the Pendle leg vs short funding.
- B05 (USDe basis) doesn't touch lisUSD or Venus borrow.
- B10-07 is the only family member that books a basis between **two CDP
  stables (lisUSD and VAI-class Venus debt) plus a fixed-yield
  derivative**, with the three legs settled on three different protocols.

## Block layout (90-day maturity hold)

1. `t = 0` — `lisUSD → PT-lisUSD` (locks PT_implied for the term).
2. `t = 0` — supply collateral, borrow USDT (capped at 50 % LTV given
   PT-lisUSD's illiquid secondary), swap USDT → lisUSD sink.
3. `t = MATURITY_DAYS` — PT redeems 1:1 lisUSD. Withdraw sink, swap back
   to USDT to repay Venus borrow + accrued cost.
4. Withdraw collateral; tally net lisUSD delta.

## Status & PnL

- **Status:** offline-only PoC. The on-fork helper `_onForkPtBuy` exists
  but is not invoked from `testStrategy_B10_07` because BSC Pendle v4 does
  not yet have a canonical PT-lisUSD market at scaffold time. We defer to
  the offline accounting until the market address is published.
- **PnL model** (`notional = $1m`, `T = 90d`):
  - PT face at maturity = `lisUSD × (1 + 12 % × 90/365) − 5 bp entry` =
    `$1,029,587`.
  - Borrow USDT at 50 % LTV = `$499,750`; borrow cost over 90d at 7 %
    APR = `$8,625`.
  - Sink yield over 90d at 2 % APR = `~$2,465`.
  - Close-leg drag = 2 × 4 bp ≈ `$400`.
  - Net 90-day PnL ≈ **$22,000 (≈ 8.8 % APR on lisUSD notional)**.

## Address / ABI verification

- `BSC.PENDLE_ROUTER_V4` is the Pendle V4 mainnet address reused on BSC;
  carries `// TODO verify` in `BSC.sol`. The on-fork branch will revert
  if the canonical BSC deployment differs.
- `LOCAL_PT_LISUSD_MARKET` is a placeholder. Promote to `BSC.sol` once
  Pendle BSC publishes the lisUSD market.
- Venus surface (`vUSDT`, `VENUS_COMPTROLLER`) sourced from `BSC.sol`.

## TODO

- Pin a real `FORK_BLOCK` and `LOCAL_PT_LISUSD_MARKET` once the Pendle
  BSC v4 lisUSD market ships.
- Tighten the PT-as-collateral leg: Venus does not currently list PT-LP
  shares; we need either (a) a Lista-DSR-style direct accept of PT, or
  (b) hold PT separately and use lisUSD itself as the Venus collateral.
  The current model uses (b).
- Replace constants `PT_IMPLIED_BPS`, `VENUS_USDT_BORROW_BPS`,
  `LISUSD_SUPPLY_BPS` with fork-time reads once the relevant view
  selectors are wired.
- Layer in Pendle YT incentive accrual as an upside-only branch (B04-03
  cousin) — out of scope for this carry-focused PoC.
