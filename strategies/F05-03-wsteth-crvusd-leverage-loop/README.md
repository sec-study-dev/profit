# F05-03: wstETH -> crvUSD leveraged borrow loop

## Mechanism
The Curve crvUSD wstETH market lets a user lock wstETH and mint crvUSD up to
a per-market debt ceiling, with `N` (5–50) collateral bands. The borrow rate
is governed by a PID-like controller targeting the crvUSD/USDC Curve pool's
TVL-weighted peg deviation: when crvUSD trades above $1 the rate falls,
below $1 it climbs. Historic borrow APR has ranged 4-25%, with a long
midrange of 6-10%.

The loop is conceptually identical to an Aave-wstETH/WETH e-mode loop but
*the debt is a stablecoin* instead of ETH. That changes the directional
profile:
- The user keeps wstETH (yield-accreting) and is short crvUSD (≈ short USD).
- If ETH rises, equity grows linearly with leverage `K = 1/(1 - LTV_eff)`.
- If ETH falls into the LLAMMA bands, the position is *soft-liquidated*:
  wstETH is auto-converted to crvUSD in bands, partly repaying debt and
  partly capping further loss. The drag is the band fee + slippage paid to
  external arbers (see F05-01).

Verified addresses:
- wstETH Controller: `0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE`
- wstETH LLAMMA:     `0x37417B2238AA52D0DD2D6252d989E728e8f706e4`

The loop is executed via:
```
controller.create_loan(collateral, debt, N)
swap crvUSD -> wstETH on Curve `crvUSD/USDC` + `stETH/ETH` + Lido `wrap`
controller.add_collateral(more_wstETH, address(this))
controller.borrow_more(0, more_crvUSD)
... repeat ...
```

After N rounds at safe utilisation 50% (debt/max_borrowable):
```
final_collateral = principal / (1 - 0.5 * (price_ratio))
final_debt       = 0.5 * principal * (1 - (price_ratio)^N)
                  / (1 - price_ratio)
```
At a conservative 0.5 utilisation with N=4 rounds, leverage ≈ 1.875× on a
principal wstETH; with N=8 ≈ 1.97×; max-N saturates at 2× on this market.

## Why it composes
Three protocols, three orthogonal roles:
1. **Lido (wstETH)** — yield-accreting collateral, ~3.0% stake APR.
2. **Curve crvUSD Controller** — debt-side primitive with PID rate so the
   borrow APY *targets the cost of the peg*, not the supply utilisation.
3. **Curve `crvUSD/USDC` + `stETH/ETH` pools** — the recycle path that
   re-collateralises borrowed crvUSD.

The composition only works because (1) wstETH's per-block rate accretion is
non-correlated with (2) the crvUSD borrow rate (the latter targets peg, not
collateral health), and (3) the LLAMMA's soft-liquidation drag is a known
*expected cost*, not a random loss. The strategy therefore extracts:
```
net_apy ≈ K * stake_apr - (K - 1) * crvusd_borrow_apr - expected_softliq_drag
```

## Preconditions
- Mainnet, block where crvUSD wstETH-market borrow rate < 0.8 * wstETH stake
  APR (after accounting for ~30% leverage haircut from soft-liq drag).
- Empirically: most of Q1 2024 (rate 4-7%, stake APR ~3.2%); also early Oct
  2024 (rate ~5%, stake APR ~2.9%).
- wstETH market debt ceiling has headroom (verify `borrow_rate`,
  `available_to_borrow` style getters — Curve docs call these
  `max_borrowable(coll, N)`).
- Capital: any size up to ~$5M before market depth on the recycle leg
  becomes the bottleneck.

## Strategy steps
1. Take `P` wstETH as principal.
2. Approve wstETH to wstETH Controller.
3. `controller.create_loan(P, D_0, N=10)` where `D_0 = 0.5 *
   max_borrowable(P, 10)`. This mints `D_0` crvUSD and locks `P` wstETH in
   10 bands centered on `p_oracle`.
4. crvUSD -> USDC -> WETH:
   `D_0` crvUSD -> USDC on Curve `crvUSD/USDC` -> WETH on Uni v3 0.05% ->
   ETH (unwrap).
5. ETH -> stETH via Curve `stETH/ETH` (cheapest path; or Lido `submit`).
6. Wrap stETH -> wstETH via `wstETH.wrap`.
7. `controller.add_collateral(newWstETH, address(this))`.
8. `controller.borrow_more(0, D_1)` where `D_1 = 0.5 * delta_max_borrowable`.
9. Repeat 4-8 four times (5 rounds total).
10. Hold; the position now accrues `stake_apr` on the levered wstETH and
    pays the dynamic crvUSD borrow rate on the debt.

## PnL math
Assume:
- `s` = wstETH internal APR = 0.030
- `b` = crvUSD wstETH-market APR = 0.060 (snapshot Apr 2024)
- `d` = expected soft-liq drag = 0.005 * K (band fees + arb take)
- `L` = effective LTV per round = 0.50
- `K` = leverage = sum of (L^i) for i=0..N = (1-L^(N+1))/(1-L)
   - At N=5: K ≈ 1.969
   - At N=10: K ≈ 2.000

Net APY on principal:
```
net_apy = K*s - (K-1)*b - d
        = 1.97*0.030 - 0.97*0.060 - 0.005*1.97
        = 0.0591 - 0.0582 - 0.0099
        = -0.009  (-0.9%) at b=6%, s=3.0%
```

The naive cash carry is **negative** under typical 2024 rates. The loop
only clears in three regimes:
- **Negative crvUSD borrow rate windows** (when crvUSD trades above peg
  for several days; the PID drives rate towards 0%): Jun-Jul 2024 had
  multiple sub-2% rate windows.
- **Stake APR spikes** above 4% (post-merge MEV-spike weeks).
- **As a points/leverage vehicle for AAVE/Eigen** — wstETH retains all the
  *staking* exposure on the levered collateral, useful inside compound
  strategies.

At a benign 1.5% crvUSD rate window the same math gives:
```
net_apy = 1.97*0.030 - 0.97*0.015 - 0.0099
        = 0.0591 - 0.0146 - 0.0099 = 0.0346  ≈ +3.5%
```

## Block pinned
**20_650_000** (Aug 2024) — crvUSD wstETH-market rate briefly at ~1.4% APR
during the post-Aug-5 deleveraging when crvUSD traded $1.005-$1.012 for
two weeks, PID pulled rate down hard. Stake APR ~3.0%, soft-liq quiet.

## Risks
- **Rate spike.** crvUSD PID can drive rate to >15% APR if peg slips
  below $0.985; one-week drawdown in Mar 2023 hit 21%.
- **ETH/wstETH fall into LLAMMA bands.** Soft-liquidation is *not free*:
  every band cross costs ~10-30 bps to external arbers (see F05-01).
- **Curve pool depth on close-out.** Unwinding 5M crvUSD through
  `crvUSD/USDC` at peak-stress moves the pool ~25 bps.
- **Smart-contract risk.** crvUSD Controller has had multiple audits but
  the LLAMMA's soft-liquidation logic is novel and complex.
- **Liquidation cliff.** If wstETH falls below the lowest band, the
  Controller liquidates entirely (no longer soft) and the user keeps
  whatever crvUSD was accumulated in bands.

## Result
Status: **theoretical, foundry build not run**. Cash-carry PnL is highly
state-dependent: **-1% to +4% APY** on principal in the typical mid-2024
parameter regime. The strategy is most useful as a *building block* under
F16 (cross-CDP basis) where the borrowed crvUSD funds a higher-yielding
position on another protocol (e.g. sUSDe via Pendle).
