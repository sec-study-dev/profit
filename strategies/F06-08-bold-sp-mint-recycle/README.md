# F06-08: BOLD SP-mint recycle on the Liquity v2 wstETH branch

2-mechanism strategy. **Family: F06 (Liquity v2 / BOLD)**.

## Mechanisms combined
1. **Liquity v2 BorrowerOperations.openTrove** (wstETH branch) — mints BOLD.
2. **Liquity v2 StabilityPool** (same branch) — recycles freshly minted
   BOLD back into the SP to harvest BOLD-interest yield + wstETH
   liquidation premium.

(Curve appears only as an exit route in production; the on-chain loop
itself is pure-Liquity v2.)

## Mechanism — self-funding SP yield
Liquity v2 routes a fraction (~75% per spec) of borrower interest
*flowing into a branch* to that branch's Stability Pool depositors. If a
borrower opens a trove at rate `r_b` and there exists average system
flow at rate `r_s > r_b`, then depositing the freshly-minted BOLD back
into the SP gives:

```
SP yield rate ≈ 0.75 × weighted-avg(r_borrower) of branch
borrower rate paid = r_b
net annual carry  = SP_yield × debt − r_b × debt
                 = (0.75 × weighted_avg − r_b) × debt
```

If our `r_b` is set at-or-below the weighted average (say 3.0% when the
branch average is 5.0%), the carry is +1.75% × debt. On a `D = 60,000`
BOLD position that's +$1,050/year of "pure protocol yield" with **zero
external swap**.

Bonus: whenever a wstETH-branch liquidation fires, the SP depositors get
wstETH at the in-protocol oracle price minus 10% (per v2 spec); over a
year of normal conditions that's worth another ~1–3% effective APY on
the SP balance.

### Why the borrower-rate position is safe
Standard objection: "low rate = redemption target". With v2 the redeemer
takes the *lowest-rate* trove's *collateral*, not BOLD. They burn BOLD
1-for-1 against debt and ship back wstETH at the per-branch oracle. If
you are redeemed:
- Your trove's debt decreases by `redeemed BOLD`.
- Your collateral decreases by `redeemed BOLD / wstETH_price`.
- You receive a redemption fee compensation (~0.5–2% × redeemed BOLD).

In the SP-mint recycle, BOLD is in the SP, NOT in your wallet — so a
redemption against your trove leaves you with reduced debt (good) and
reduced collateral (bad, but reduces leverage too). Net: SP balance is
unchanged, the trove just gets de-leveraged.

## Why it composes (within v2 alone)
The Liquity v2 design intentionally lets borrowers also be SP
participants — there's no protocol-level lockout. This is the cleanest
2-mechanism strategy in the family: same protocol, two pools.

## Preconditions
- Wstr-branch BorrowerOperations and StabilityPool live (post May 2025
  redeployment).
- Branch SP has positive deposits so our share isn't 100%.
- Our chosen `ANNUAL_RATE = 3.0%` < branch weighted-avg rate (which
  has historically been 4.5–6% on the wstETH branch).

## Strategy steps
1. Fund with 50 wstETH equity.
2. `openTrove(this, 0, 50e18 wstETH, 60_000e18 BOLD, ..., rate=3%, ...)`
   → ICR ≈ 333% at wstETH=$4000.
3. `provideToSP(60_000e18, doClaim=false)` on the same-branch SP.
4. Compound loop (3 × 30 days):
   a. Advance 30 days.
   b. Read `getDepositorYieldGain()` (BOLD yield) +
      `getDepositorCollGain()` (wstETH liquidation gain).
   c. `withdrawFromSP(0, true)` to sweep the gains.
   d. Re-`provideToSP(newBoldBalance, false)`.
5. Final read of `getCompoundedBoldDeposit()` and wstETH balance is the
   yield captured over the 90-day horizon.

## PnL math
For `D = 60,000 BOLD`, `r_b = 3.0%`, branch weighted-avg `r_s = 5.0%`,
90-day horizon, no liquidations (worst-case for the SP-gain leg):
```
SP yield (90d)   = 0.75 × 5.0% × 60_000 × (90/365) = $555
Trove interest   = 3.0% × 60_000 × (90/365)        = $443
Net (no liqs)    = +$112 (90d) on $200k wstETH equity = +0.06%
Annualised       = ~+0.23%/yr (without liquidations)

With moderate liquidation flow (e.g. 1% of branch SP balance hit per
90d, our SP share ~5%, 10% discount on wstETH):
SP wstETH gain   = 0.05 × 60_000 × 0.01 × 0.10  ≈ 3 wstETH liquidation share
                 ≈ $300 in wstETH at $4000 each
Total 90d        = +$112 + $300 = +$412 on $200k equity = +0.21%
Annualised       = +0.83%/yr

PLUS: the 50 wstETH equity still earns Lido stake yield (~3.2%/yr).

Effective total: 3.2% + 0.83% ≈ +4.0%/yr on equity — vs plain wstETH
holding (3.2%) the strategy adds 0.8 percentage points with materially
the same collateral exposure.
```

The number scales with the size of borrower-rate disparity. If we open
at 1.5% (close to the rate floor) on a branch averaging 6%, the carry
roughly doubles.

## Block pinned
- `FORK_BLOCK = 22_500_000` (post-redeployment, mid-June 2025).
  **STATUS = structural** — branch addresses gated on registry probe.

## Risks
- **Redemption queue.** Our trove is among the lowest-rate; if BOLD
  trades persistently below $1, redeemers pick our trove first. The
  trove de-leverages; if it crosses the MIN_NET_DEBT floor the
  redemption stops, otherwise BOLD debt → 0 over time.
- **SP same-branch tail risk.** A catastrophic wstETH drop liquidates
  *into* the SP. SP depositors are the ultimate buyer of last resort —
  in normal conditions this is +EV (10% discount), in a 50% wstETH
  crash with cascading liquidations the SP's BOLD claim is consumed
  before all positions can be unwound.
- **Rate floor changes.** v2 governance can adjust the minimum
  annualInterestRate; our position would need a rate bump.
- **`MIN_NET_DEBT` floor** (~2000 BOLD per v2 spec) means small troves
  can be redeemed to zero, leaving stranded collateral.

## Result
Status: **structurally complete**; gated on per-branch address
resolution from the CollateralRegistry post the May 2025 redeployment.

PnL range:
- No liquidations: **+0.2–0.4%/yr above plain wstETH hold**.
- Moderate liquidation flow: **+0.7–1.5%/yr above plain wstETH hold**.
- All cumulative on the same wstETH equity that's already earning Lido
  stake yield (~3.2%/yr base).
