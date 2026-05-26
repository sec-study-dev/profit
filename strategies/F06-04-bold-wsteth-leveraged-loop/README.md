# F06-04: Leveraged BOLD borrow loop against wstETH on Liquity v2

## Mechanism (Liquity v2 specific)
Liquity v2 has a per-collateral-branch architecture. The **wstETH branch**
accepts wstETH as collateral and lets borrowers mint BOLD against it. Two v2
features make a leveraged loop attractive:

1. **Borrower-set interest rate**: the borrower picks an `annualInterestRate`
   at trove creation. Higher rates protect against redemption; lower rates
   minimise carrying cost but expose to early redemption. The loop strategy
   picks a rate that survives the *expected* redemption flow while staying
   below the wstETH staking yield.
2. **Stability Pool yield from same branch**: each branch has its own
   Stability Pool that earns wstETH (the branch collateral) from liquidations.
   A leveraged borrower can deposit a portion of borrowed BOLD into the SP to
   harvest liquidation premium, partially offsetting interest cost.

### Loop construction
```
                  ┌──────────────────────────────────────┐
   equity (wstETH)│                                      │
       │          │                                      ▼
       ▼          │                            redeposit wstETH
   openTrove(wstETH, BOLD, rate) ──► receive BOLD ──► Curve BOLD/USDC ──► USDC
                                                                          │
                                                                          ▼
                                                   USDC ──► wstETH (Curve)
                                                                          │
                                                                          └──┐
                                                                             │
                                                                             ▼
                                                                       loop N×
```

Equivalent to a Maker/Compound recursive loop, but:
- Borrow asset = BOLD (newly minted, deeply pegged once Stability Pools are
  seeded).
- Borrow rate = whatever the user chose (not a curve-based utilisation rate).
- Collateral = wstETH (earns Lido staking yield, ~3.0% APY).
- Hard ICR floor = 110% (or 150% in recovery mode — TODO verify v2 thresholds).

### Yield identity
```
net_APY = leverage × (wstETH_stake_APY − BOLD_user_rate − redemption_drag)
       + SP_LiquidationPremium_on_idle_BOLD
       - BOLD_swap_cost_per_loop
```

`redemption_drag` is the expected fraction of the trove redeemed per year times
the redemption fee. Pick `BOLD_user_rate` strictly above the long-run median to
push our trove out of the redemption queue (so `redemption_drag ≈ 0`), while
keeping it below `wstETH_stake_APY`.

For wstETH stake yield 3.2% and BOLD_user_rate 2.5% at 5× leverage:
```
net_APY ≈ 5 × (3.2% − 2.5% − 0%) = +3.5% on equity
```

Modest, but the wstETH leg can be additionally leveraged against Aave/Morpho
in F01-style loops for compound yield (cross-family composition, but the
*originating* family is F06).

## Why it composes
- **Curve BOLD/USDC + Curve wstETH/ETH/USDC routes** are the canonical BOLD
  ↔ wstETH conversion path (no native swap exists at protocol level).
- **Liquity v2 `BorrowerOperations.openTrove`** (v2 overload, takes
  `annualInterestRate`) is the only call that mints BOLD.
- **Per-branch Stability Pool** lets us park idle BOLD inside the same
  protocol to harvest liquidation premium denominated in wstETH — same
  asset as our collateral.

## Preconditions
- Liquity v2 deployed with the wstETH branch live.
- `BorrowerOperations` reachable at the fork block and not paused.
- BOLD/USDC pool TVL ≥ $5M so the swap leg doesn't blow up.
- wstETH stake APY > BOLD_user_rate by ≥ 50 bps.
- Trove `MIN_NET_DEBT` (~2000 BOLD by v2 spec) cleared by initial equity.

## Strategy steps
1. Fund strategy with `EQUITY` wstETH.
2. Approve `BorrowerOperations` for wstETH.
3. `openTrove(owner=this, ownerIndex=0, collAmount=equity*N,
   boldAmount=equity*(N-1)*0.95, upperHint=0, lowerHint=0,
   annualInterestRate=2.5e16, maxUpfrontFee=type(uint256).max,
   addManager=0, removeManager=0, receiver=this)` — but `equity*N` we don't
   yet have. So the loop is *bootstrapped via a wstETH flashloan*:
   - Balancer V2 flashloan `equity*(N-1)` wstETH (zero fee).
   - Combine with our equity → `equity*N` wstETH posted as collateral.
   - Mint `BOLD_amt` BOLD against it (sized so ICR ~140%).
   - Curve BOLD → USDC → wstETH.
   - Repay Balancer flash.
4. Optional: deposit a portion of remaining BOLD into the wstETH-branch SP.
5. Multi-block: warp 30 days, observe interest accrual + (synthetic) SP gain.

## PnL math
For `EQUITY = 10 wstETH`, `N = 5×`, wstETH spot = $4,000 (post-Lido upside),
wstETH stake APY = 3.2%, BOLD rate set to 2.5%:

```
collateral  = 50 wstETH = $200k
debt        = ~$140k BOLD (ICR 143%)
equity      = $60k → wait this is bigger than initial $40k…

Actually equity in wstETH terms remains 10 wstETH on close. We earn:
  + stake yield on 50 wstETH    = 50 × 3.2% = 1.6 wstETH / yr ≈ $6,400
  − BOLD interest on 140k        = 140k × 2.5% = $3,500 / yr
  − redemption fee (low if rate above median) ≈ 0
  − openTrove upfront fee (~0.5% × debt) = $700 one-time
  − Curve swap drag (one-time + at unwind) ≈ 30 bps × $140k = $420 round-trip

  Net year-1 = $6,400 − $3,500 − $700 − $420 = +$1,780 on $40k equity = +4.4%
  Net year-2 = $6,400 − $3,500 − $420 = +$2,480 on $40k equity = +6.2%
```

Compared to plain wstETH stake (3.2%), the loop adds ~1.2–3.0% on equity per
year, with the variance coming from BOLD redemption flow and the price of
BOLD ↔ wstETH at unwind.

## Block pinned
- **`FORK_BLOCK = 21_500_000`** (≈ late Dec 2024) — by which time the wstETH
  branch should be live. **STATUS = theoretical** because:
  - Mainnet.BOLD == address(0) currently
  - Branch-specific `BorrowerOperations`, `ActivePool`, etc. need address
    confirmation.

## Risks
- **Redemption hits our trove.** If we set the rate too low, redeemers eat
  our collateral first. Mitigation: pick a rate above the running median
  *and* monitor; v2 allows `adjustTroveInterestRate` cheaply (upfront fee
  scaled by amount of rate change).
- **BOLD depeg up.** If BOLD trades > $1, the BOLD→wstETH leg costs extra,
  reducing leverage; the loop becomes uneconomic.
- **wstETH price drop.** Standard liquidation risk; v2 ICR floor 110%
  (TODO verify) means a ~21% wstETH/USD drop with no top-up triggers
  liquidation by the wstETH-branch SP.
- **v2 governance changes.** Rate floor/cap, redemption fee schedule, or
  branch parameter tweaks (LLTV equivalents) could change the loop math.
- **Trove cap.** v2 may impose per-branch debt caps; an opened trove may be
  rejected if cap is hit.

## Result
Status: **theoretical** until v2 mainnet addresses are wired into
`Mainnet.sol`.

PnL range (1y, 10 wstETH equity at 5× leverage):
- Calm regime: **+$1.5k – $3k on $40k equity (+4–7% IRR over base stake)**.
- With SP-yield top-up from same-branch liquidations: **+$3k – $5k (+7–12%)**.
- Worst case (BOLD spikes / redemption hits us): **flat-to-mild-negative**
  versus plain wstETH stake.
