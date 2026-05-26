# F16-06: crvUSD LLAMMA → swap to GHO → Aave V3 GHO-collateral USDC borrow

## Mechanism

A 3-mechanism cross-CDP refinance loop that **synthetically mints GHO at
the crvUSD rate** by:

1. **Curve crvUSD LLAMMA** (wstETH market) — borrow crvUSD against wstETH
   collateral at the per-second algorithmic rate (typically 4-7% APR on
   the wstETH market).
2. **Curve GHO/crvUSD StableNG pool** — swap crvUSD into GHO at near-1:1.
   This is the only on-chain venue with non-trivial GHO depth that does
   not require routing through Aave's GHO mint path.
3. **Aave V3** — supply the swapped GHO as collateral (GHO became Aave
   collateral-eligible after the Aave Risk-V3 spell in 2024), then borrow
   USDC against it.

The cross-CDP edge: Aave's GHO borrow rate is set by a governance
proposal and historically sits in the 5-9% range. Curve's crvUSD
wstETH-market rate is algorithmic and tracks the price-action of crvUSD
(typically 4-7% APR). When `r_GHO_Aave > r_crvUSD_LLAMMA + swap_fee`, a
position that wants USDC against GHO can save 100-300 bps by minting
crvUSD on LLAMMA instead of borrowing GHO directly.

## Why it composes

The three CDPs are all collateral-backed but use different rate setters:

- **Curve LLAMMA**: per-second rate from monetary policy contract; rate
  depends on the crvUSD market price (PegKeeper feedback).
- **Aave V3 IRM**: linear utilisation curve below `optimal_utilisation`,
  steep above it; rate updates every block as utilisation changes.
- **Aave GHO**: fixed APR governance-set; bucket-rationed.

Because GHO's "cost-of-mint" through Aave is the governance APR, but its
"cost-of-mint" via Curve is `crvUSD_rate + swap_fee`, the trader can
**arbitrage the two cost curves** as long as a Curve GHO/crvUSD pool
exists with depth. The pool exists because Aave-DAO funded its bootstrap
liquidity in late 2024.

The wstETH collateral additionally accrues Lido stETH staking yield
(~3% APR), which subsidises the LLAMMA borrow leg. The full cost-of-USDC
on this stack:

```
cost_of_USDC = r_LLAMMA_crvUSD + swap_fee_curve - wstETH_yield_lido
             + r_USDC_borrow_aave - 0     (USDC is the funded output)
```

Compared to "supply USDC, borrow GHO, sell GHO", which has cost:

```
cost_of_USDC_naive = r_GHO_borrow_aave + sell_loss_GHO->USDC
```

The break-even is `r_GHO_Aave > r_crvUSD_LLAMMA + total_swap_fee
- wstETH_yield`. For 2024-2025 mainnet, this hurdle is met most of the
time.

## Preconditions

- Curve crvUSD wstETH-market live (controller
  `0x100dAa78fC509Db39Ef7D04DE0c1ABD299f4C6CE`).
- Curve GHO/crvUSD pool `0x635EF0056A597D13863B73825CcA297236578595` live.
- GHO listed on Aave V3 as a collateral-eligible reserve. The PoC reads
  the LTV bits at runtime and bails out if LTV == 0.
- Aave V3 USDC reserve has borrowable headroom.

PoC pins block **20_700_000** — late Sep 2024.

## Strategy steps

1. Fund operator wstETH equity (100 wstETH).
2. `Controller.create_loan(WSTETH_EQUITY, 55% of max_borrowable, N=10)`.
3. `Curve(GHO/crvUSD).exchange(1, 0, crvUsdBorrow, 0)` — crvUSD → GHO.
4. `Aave.supply(GHO, ghoHeld, this, 0)`.
5. `Aave.setUserUseReserveAsCollateral(GHO, true)`.
6. `Aave.borrow(USDC, 65% of GHO USD value, mode=2)`.
7. Warp 30 days; read LLAMMA debt + Aave account data; surface PnL.

## PnL math

Pinned-block parameters:
- wstETH price ≈ $3,100 (post-stETH 1.18 wrap), so 100 wstETH ≈ $310,000.
- LLAMMA `max_borrowable` ≈ $217,000 crvUSD (effective LTV ~70%).
- 55% of max → crvUSD borrowed ≈ 119,350.
- crvUSD → GHO swap fee ≈ 4 bps → GHO held ≈ 119,300.
- GHO Aave LTV ≈ 75% (collateral-eligible reserve).
- 65% of GHO value borrowed as USDC → USDC drawn ≈ 77,545.
- USDC borrow rate ≈ 6% APR.
- crvUSD LLAMMA rate ≈ 6% APR.
- GHO Aave variable borrow rate (the avoided rate) ≈ 9% APR.

Compared to naive "supply USDC, borrow GHO, sell GHO" path for the same
USDC outcome:

```
saved_per_year = USDC_drawn * (r_GHO_Aave - r_crvUSD_LLAMMA - swap_fees_amortised)
               = 77_545 * (0.09 - 0.06 - 0.008)
               = 77_545 * 0.022
               = $1_706 / year

annualised_edge = 1706 / 77_545 = 2.2% / year on the USDC notional
```

On wstETH equity ($310k), the carry is dominated by the LLAMMA cost
(-$7.1k) offset by wstETH yield (+$9.3k from 3% Lido APR), net +$2.2k +
the $1.7k cross-CDP refinance savings = **~$3.9k / yr ≈ 1.3% APR** on
equity, or **~6.5% APR** on the USDC produced (which is the productive
liquidity).

The trade is positional, not atomic. The realised PnL across 30 days is
the rate-spread savings (~$140 / 30d) plus LST yield (~$770 / 30d) minus
LLAMMA debt service (~$590 / 30d) ≈ **+$320 / 30d on $310k wstETH**.

## Block pinned

`20_700_000` — late Sep 2024. Selected because:
- GHO was collateral-eligible on Aave V3 (post the Aave Risk Committee
  spell).
- GHO/crvUSD Curve pool had bootstrapped liquidity (~$15M depth).
- crvUSD wstETH-market rate was at the low end of its 2024 band (~6%),
  maximising the basis vs. Aave GHO rate (~9%).

## Risks

- **GHO collateral LTV reduction** — Aave governance can lower the GHO
  collateral LTV at any time, forcing partial repayment.
- **crvUSD wstETH-market rate spike** — if crvUSD trades over-peg, the
  algorithmic rate jumps to 10%+ APR. The PoC's snapshot rate is read at
  `setUp`, so a mid-test spike would crush the carry.
- **GHO/crvUSD pool liquidity drain** — the pool has only Aave-DAO
  seeded liquidity; a large draw can move the swap price 20+ bps.
- **LLAMMA soft-liquidation** — wstETH price drop into the band range
  partially converts wstETH to crvUSD at a discount, locking in a loss
  on the collateral side.

## Result

Status: full open path implemented end-to-end. Expected 30-day carry at
pinned-block parameters ≈ **+$300-500 on 100 wstETH equity** (1-2% APR on
equity, ~6% APR on the USDC produced). The strategy is most valuable as a
**rate-arbitrage refinance tool** rather than a yield generator: it lets
USDC borrowers escape Aave's GHO rate when LLAMMA is cheaper, saving
~200 bps on the borrow leg.
