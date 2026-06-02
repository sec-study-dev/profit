# B14-08: PT-lisUSD-savings cash-and-carry — BSC variant of F07-08

## Mechanism (1-mech, pure-discount carry)
This is the BSC analogue of the mainnet `F07-08` PT-sUSDS cash-and-carry,
adapted to Lista's lisUSD savings wrapper. The mechanism is a single
clean discount-capture:

1. Buy `PT-lisUSDsavings-26JUN2025` on Pendle BSC at a fixed discount
   (`ENTRY_PRICE_E18 ≈ 0.965` USDT per PT) corresponding to ~7 % implied
   APR over the 6-month time-to-maturity.
2. Hold to maturity. PT redeems 1:1 for SY-lisUSD, then SY redeems 1:1
   for lisUSD.
3. Exit back to USDT via the Wombat lisUSD main pool.

There is no leverage, no rotation, no token-incentive — the carry is
purely the convergence of PT spot to par as the underlying lisUSD
savings APR accrues into the wrapper.

## Why it composes
- PT is **fungible and transferable** until maturity; redemption requires
  no permission. The carry is locked in at entry, and the discount-rate
  cannot widen against you after the entry transaction.
- Lista's lisUSD savings rate is published on-chain (`lisUSD savings APR`),
  so the implied discount on PT is observable real-time — entries can be
  timed when PT trades 50 bp+ wide of fair.
- 100 % offline-projectable: the closed-form `gross_carry = principal ×
  (1/entry − 1)` doesn't need an iterative LTV / IRM model.

## Preconditions
- Pendle BSC market for PT-lisUSD-savings is live with ≥ $2M TVL
  (so a 100k USDT entry costs ≤ 30 bp).
- Wombat lisUSD/USDT pool depth ≥ $5M (covers entry + exit at ≤ 25 bp
  each).
- Holding period covers full time-to-maturity (no early-exit modelled
  here; an early-exit variant would re-quote on the AMM).

## Strategy steps (100k USDT, 180-day hold)
1. `_fund` 100k USDT.
2. Swap USDT → lisUSD via Wombat (~30 bp drag, including peg basis).
3. Use Pendle router to swap lisUSD → PT-lisUSD-savings at $0.965.
4. Hold to maturity (180 days modelled).
5. Redeem PT 1:1 to SY-lisUSD, SY → lisUSD.
6. Swap lisUSD → USDT via Wombat (~25 bp drag).
7. PnL = `principal × (1/entry − 1) − entry_drag − exit_drag`.

## PnL math (100k USDT, 180-day horizon, entry $0.965)
- Effective lisUSD into PT after 30 bp entry drag: `99,700 lisUSD`.
- PT shares received: `99,700 / 0.965 = 103,316 PT`.
- At expiry, PT redeems 1:1 → `103,316 lisUSD`.
- After 25 bp Wombat exit drag: `103,058 USDT`.
- Net PnL: `103,058 − 100,000 = +3,058 USD ≈ +3.06 %` over 180d
  (~**+6.2 % annualised**).

Compare to **plain sUSDX / lisUSD-savings hold** at spot 6 % APR for
180d: `6 % × 180/365 × 100k = +2,959 USD`. The PT lock captures
**+99 USD or +10 bp** of extra implied-rate over spot, which is the
classic Pendle PT premium for taking on no-early-exit risk.

The PT win-vs-spot magnitude tracks the *implied-vs-spot APR gap* at
entry time. Typical Pendle BSC PT premia are 50–150 bp; we model 20 bp
here as a conservative case.

Gas: 4 tx (Wombat in + Pendle PT in + Pendle PT redeem + Wombat out)
≈ 1.5M gas × 1 gwei × $600/BNB ≈ `$0.9`.

## Block pinned
**42_000_000** (Mid Q1 2025). Re-pin once Pendle PT-lisUSD-savings
BSC market is verified live. Strategy assumes the modelled expiry
`1750896000` (26-JUN-2025 00:00 UTC) is past the fork block by
~180 days.

## Addresses used
- `0x55d398326f99059fF775485246999027B3197955` — USDT.
- `0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5` — lisUSD.
- `0x888888888889758F76e7103c6CbF23ABbF58F946` — Pendle Router V4.
- `0x19609B03C976CCA288fbDae5c21d4290e9a4aDD7` — Wombat Router.
- `0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0` — Wombat Main Pool.
- `LOCAL_PT_LISUSD_MARKET` (`0x...B14080`) — placeholder.
- `LOCAL_PT_LISUSD` / `LOCAL_SY_LISUSD` / `LOCAL_YT_LISUSD` —
  placeholders.

## Risks
- **lisUSD depeg at expiry**: PT redeems to lisUSD 1:1, then the
  exit swap to USDT lands at lisUSD spot. A 1 % depeg costs
  `1 % × 103k = $1,030`, wiping out the carry. Mitigated by sizing
  expiry to overlap with low-volatility windows; Pendle PT itself
  is immune to mid-life depeg if held to maturity.
- **Pendle BSC market not live at modelled expiry**: PT cannot redeem
  through canonical paths. PoC falls back to manual
  `YT.transferAndCall(redeemPY)`.
- **Lista savings module deprecation**: governance-level risk. If
  the lisUSD-savings wrapper underlying the PT is sunset, PT becomes
  unredeemable; mitigated by Pendle's expiry redemption being
  hard-coded against the SY contract (not the live savings module).
- **Wombat depeg slippage at exit**: a stressed lisUSD pool widens
  exit drag from 25 bp to 50 bp+. The PT premium is large enough to
  absorb this in most regimes.

## Result
Status: **theoretical** — BSC RPC + Pendle PT-lisUSD-savings BSC
market not yet verified. Expected PnL: **+3.06 % over 180 days on
100k USDT principal**, **+10 bp** above spot-hold, decomposed as
~98 % from PT discount convergence and the rest from the 20 bp
implied-vs-spot rate gap.

## TODO
- Verify Pendle PT-lisUSD-savings BSC market address + expiry
  timestamp via Pendle subgraph.
- Sample live PT entry price closer to the pinned block (`42_000_000`)
  and replace `ENTRY_PRICE_E18` with the observed value.
- Add an early-exit variant where the PT is sold back into the Pendle
  AMM at a re-quoted discount (mid-life mark) instead of held to
  maturity.
