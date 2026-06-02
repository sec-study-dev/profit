# B15-10 — Venus VAI mint · Pendle PT-USDT · Wombat stable LP stack

## Family

B15 · 三协议机制堆叠. Stable-side triple stack — Venus credit
(VAI mint) → Pendle fixed yield → Wombat LP fees, with three
**structurally different yield curves** stacked on a single
USDC equity seed.

## Thesis

Venus's native VAI mint is *separate* from the regular borrow market:
any Venus account can mint VAI against its aggregate collateral
at a one-shot fee (~1%), no per-block interest. This makes VAI
the cheapest stable credit on BSC for buy-and-hold strategies.
Routing the freshly-minted VAI through Wombat (the best VAI/USDT
on-chain venue) into USDT, then splitting between:

- **60% Pendle PT-USDT** for a fixed ~10% APR locked to a maturity
  (PT decay → par at maturity is mechanically certain), and
- **40% Wombat 3-stable LP** for floating fees + WOM emissions
  (anti-correlated to PT — Wombat earns most when stables wobble,
  exactly when PT marks down),

produces a stable carry that is *both* fixed-rate (PT) and
floating-fee (LP) at the same time.

## The 3 mechanisms

1. **Venus VAI mint** — `vUSDC.mint(USDC)` + `VAIController.mintVAI`.
2. **Pendle BSC PT-USDT** — `IPendleRouter.swapExactTokenForPt`.
3. **Wombat 3-stable LP** — `IWombatPool.deposit(USDT)`.

## Why distinct from B15-01..06

- B15-01 mints **lisUSD** via Lista (not VAI via Venus), and uses
  Pendle on **USDe** (not USDT). Different CDP, different PT asset.
- B15-03 is an atomic flash with PT-sUSDe; no VAI, no Wombat LP.
- B15-05 is a Lista CDP + Wombat + PCS stable basis loop with no
  Pendle leg at all.
- B15-10 is the only B15 strategy that pairs **Venus's native
  stablecoin mint** with **Pendle PT** alongside an **independent
  Wombat LP** position.

## TODO

- Verify `LOCAL_VAI_CONTROLLER` address against Venus's actual
  deployment; placeholder address is a stand-in.
- Confirm Pendle BSC PT-USDT-26JUN2025 market exists at the pinned
  block.
- Re-tune the 60/40 PT/LP split once on-chain WOM emissions for the
  3-stable pool are sampled.
