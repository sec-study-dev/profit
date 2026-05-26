# F04-05: DaiUsds round-trip + sUSDS slippage probe

## Mechanism

This is the **base-case PoC** that every other Maker/Sky strategy in F04 leans
on. We measure whether the two primitives Sky governance markets as
"frictionless" are *actually* frictionless:

1. **DaiUsds wrapper** (`0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A`). Sky's
   official DAI <-> USDS converter. Marketed as zero-fee, 1:1, atomic. Wraps
   the Maker `DAI_JOIN` and the USDS `MCD_LITE_PSM`.
2. **sUSDS** (`0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD`). ERC-4626 over USDS,
   accruing the Sky Savings Rate (`ssr()` in RAY/sec). Standard 4626 rounding
   semantics: `deposit` rounds shares *down*, `redeem` rounds assets *down*.

Three sub-tests:

- **`test_daiUsdsPureRoundTrip`** — `DAI -> USDS -> DAI` with a 1 M DAI probe.
  Asserts the wrapper conserves balance to the wei. No SSR involved, so any
  non-zero loss here is direct evidence the wrapper isn't actually 1:1.
- **`test_daiUsdsSUsdsZeroWarpRoundTrip`** — `DAI -> USDS -> sUSDS shares ->
  USDS -> DAI` with **no warp**. Tolerates up to 2 wei of total loss
  (`MAX_ROUND_TRIP_LOSS_WEI = 2`). This 2-wei budget is intentionally tight: 1
  wei loss per 4626 round-down (one on `deposit`, one on `redeem`) and 0 from
  the wrapper.
- **`test_susdsRateAccrual`** — 60-day warp + `drip` to confirm the SSR rail
  actually accrues. Asserts the redeemed USDS strictly exceeds the deposited
  USDS, and the gain is bounded into a sane SSR range (40 bps to 500 bps over
  60 days, i.e. 2.5% to 30% APR equivalent).

## Why it composes

Every leveraged F04 loop multiplies whatever per-cycle slippage exists in
DAI<->USDS<->sUSDS by the loop count. At 5 iterations a 1 bp per-leg loss
becomes a 5 bp drag on the entire loop's APY — enough to invert the SSR -
Spark spread. This PoC pins down the actual wei-level cost so other loops can
report tight PnL bounds.

It also serves as a regression test: if Sky governance ever attaches a fee
(`tin`/`tout`) to the DaiUsds wrapper or changes the `MCD_LITE_PSM` topology,
this PoC starts failing immediately, while a leveraged loop might just look
"slightly less profitable" and ship the bug.

## Preconditions

- Block where sUSDS is deployed and SSR > 1 RAY (i.e. positive yield).
- DaiUsds wrapper is not paused. Sky has the right to pause for migration
  spells; an emergency-pause block would show one of the asserts failing.

## Strategy steps

Per sub-test, all in one tx (only sub-test 3 has a warp):

```
sub-test 1:   DAI --daiToUsds--> USDS --usdsToDai--> DAI   (assert exact)
sub-test 2:   DAI --daiToUsds--> USDS --deposit--> sUSDS
              sUSDS --redeem--> USDS --usdsToDai--> DAI    (assert <= 2 wei loss)
sub-test 3:   DAI --daiToUsds--> USDS --deposit--> sUSDS
              warp 60d, drip
              sUSDS --redeem--> USDS --usdsToDai--> DAI    (assert strict growth)
```

## PnL math

Sub-test 1: PnL == 0 exactly (1:1 wrapper).

Sub-test 2: PnL is `-2 wei` worst case on a 1 M DAI probe — i.e. `-2e-18 / 1e6 ≈
-2e-24` relative. Completely negligible but *audited*.

Sub-test 3: PnL is the realized SSR yield over 60 days minus the round-trip
wrapper loss. At SSR = 6.5% APR:
```
gain ≈ PROBE * ((1 + 0.065/365)^60 - 1) ≈ 1_000_000 * 0.01077 ≈ 10_770 DAI
```
on a 1 M DAI probe. Gas: ~250 k gas (one wrap, one deposit, one redeem, one
unwrap, plus drip) — at 20 gwei and ETH=$3400 that's $17. Net ≈ +$10,750.

## Block pinned

`21_500_000` — same anchor as F04-03 so the SSR is in its post-Sky-launch
positive-yield regime.

## Risks

- **Wrapper pause / migration.** Sky can pause the DaiUsds wrapper. Test will
  revert; that's a feature not a bug — the upstream loops should fail loudly
  rather than silently route through Curve at a wider spread.
- **SSR drop to zero.** If Sky governance sets `ssr() = 1 RAY` (1.0 in RAY,
  i.e. zero yield), sub-test 3 fails the lower-bound. That's the correct
  signal — a zero-yield SSR invalidates the whole F04 thesis.
- **4626 rounding regression.** If a Maker contract upgrade changes sUSDS
  rounding to lose >2 wei per cycle, every leveraged sUSDS loop in this family
  needs to relax its bounds — this PoC will catch it first.

## Result
Status: mechanically-reproducible
Expected PnL: ~0 DAI on sub-tests 1 and 2 (within 2 wei); +1.07% (~$10,770 / +6.5% APR-equivalent) on 1M DAI over 60 days for sub-test 3

A two-mechanism (DaiUsds + sUSDS-4626) round-trip probe with three asserting
sub-tests. Establishes the wei-level cost basis under every Maker/Sky
leverage loop in F04. PnL: zero on sub-tests 1 and 2; ~ +1% on the 60-day
SSR sub-test.
