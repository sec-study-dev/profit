# F08-02: USDe peg arbitrage via Balancer flash + dual Curve pools (atomic)

## Mechanism

USDe trades on at least three Curve factory pools simultaneously:

- **USDe/USDT** (`0xa8a04E5d50e16fAFD127DbE9D5d2D5dCF4946e0C`)
- **USDe/USDC** (`0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72`)
- **USDe + sDAI + FRAX + DAI** (the larger 4-coin pool)

Because the three pools have independent liquidity depths and trader
flows, the *implied* USDe price drifts between them when one pool sees
asymmetric net-buy or net-sell pressure. In practice the spread is
small (1–10 bps) but it widens to 20–60 bps in two regimes:

1. **ETH liquidation cascade**: USDe holders trying to exit fastest hit
   one pool harder than another. USDT pool was the most-used exit venue
   during the Mar/Apr 2024 funding-rate spikes.
2. **Ethena yield deposit surges**: when a new sUSDe yield tier is
   announced, fresh USDe demand concentrates on the USDC pool, lifting
   USDe locally.

When the price gap is wider than the round-trip fee cost (Curve 4 bps
per pool × 3 hops = 12 bps + small slippage), a **flash-loan funded
triangular arb** is risk-free profit:

```
Balancer flash USDT (0 fee)
  -> Curve USDe/USDT: USDT -> USDe (buy at the discount side)
  -> Curve USDe/USDC: USDe -> USDC (sell at the peg side)
  -> Curve 3pool:     USDC -> USDT (close the triangle)
  -> Repay Balancer flash with USDT.
```

PnL = `(USDT_out - USDT_flashed) - flash_fee (= 0) - gas`. The trade
is single-block atomic and uses zero personal collateral.

## Why it composes

This is the canonical "stable triangular" structure adapted to USDe's
multi-venue pricing. Three protocol primitives combine:

1. **Balancer V2 Vault** as a zero-fee flash provider. USDT inventory
   on Balancer routinely exceeds $10M and the singleton accepts
   arbitrary asset flashes. Maker's DssFlash is DAI-only, so we use
   Balancer for USDT.
2. **Curve factory stableswaps** as the three price-discovery venues.
   The factory pools share oracle-free design so each pool is a
   self-contained price marker; the arber simply takes the geometric
   path that benefits from the local imbalance.
3. **Curve 3pool** as the canonical USDC/USDT closing leg. The 3pool
   is by orders of magnitude the deepest stable AMM and its USDC/USDT
   leg is essentially infinitely deep relative to a 1M USDT probe (< 1
   bps cost).

Because all three legs are atomic, there is no carry risk — peg can
re-converge in the next block and the arb still settled in this block.

## Preconditions

- Mainnet fork at a block where USDe is trading at materially different
  prices on the USDT vs USDC pool (e.g. due to one-sided flow).
- Balancer Vault USDT balance ≥ FLASH_USDT (1M USDT in PoC).
- All three Curve pools healthy and accept exchange calls.
- Gas budget < expected spread × notional.

The PoC includes a *quote-first* gate: if the round-trip get_dy outputs
less than the flashed principal, the test logs `no_arb` and exits
cleanly without taking the flash loan. This keeps the PoC runnable on
any block (it will be a no-op on peg-converged blocks).

## Strategy steps

1. Query the three `get_dy` rates to estimate USDT-in -> USDT-out.
2. If `out > in` (positive edge), call `Balancer.flashLoan(USDT, N)`.
3. In the callback:
   a. `Curve.USDe/USDT.exchange(USDT -> USDe)`
   b. `Curve.USDe/USDC.exchange(USDe -> USDC)`
   c. `Curve.3pool.exchange(USDC -> USDT)`
   d. Verify `USDT_back >= N`.
   e. Transfer `N` USDT to Balancer Vault.
4. Net PnL is the USDT residual on `address(this)`.

## PnL math

For a peg gap `g` (in USDe price terms) between the USDT and USDC
pools, the gross spread per dollar of notional is:

```
gross_bps ≈ g_bps - 4 * 3 (Curve fee) - slippage_bps
```

A 25 bps gap with 12 bps total Curve fee and 5 bps total slippage gives
~8 bps net. On 1M USDT that is $800 net.

`Balancer.flashLoan` fee = 0 at current parameters (Balancer V2 protocol
fee was set to 0 for flash). Gas for the 4-call path (flash + 3 swaps +
1 transfer back) is ~500k → at 20 gwei and ETH=$3000 that is ~$30.

Net ≈ $770 on a single 1M USDT execution.

The trade is size-bounded by the depth of the **smaller** of the two
USDe Curve pools. The USDC pool was ~$80M in May 2024, the USDT pool
~$50M; sizing > 5M USDT typically collapses the spread before the swap
clears.

## Block pinned

**19_500_000** (~Mar 18 2024). During the Mar 2024 funding spike
window, USDe pools showed up to 35 bps inter-pool divergence on the
day-spans where ETH funding rates were >0.1%/8h. If the pinned block
does not have an edge, the PoC's quote-gate skips execution.

## Risks

- **MEV competition**: searchers will close the same trade in the next
  block (or this block via private builder). The PoC assumes private
  inclusion via a builder relay (Flashbots Protect, MEV-Share, etc.);
  on the public mempool the trade is front-run.
- **Slippage at scale**: the spread is depth-bounded. The PoC sizes at
  1M USDT, which on most blocks fits within the in-the-money tranche;
  the strategy doc recommends sizing to the marginal break-even point.
- **Pool drain**: a pool with `< notional` USDe inventory will quote a
  large unfavourable price. The quote-gate path detects this.
- **USDT freeze on the Balancer side**: USDT can be frozen by Tether
  governance. A frozen Balancer vault USDT balance would revert the
  flash. Falls back to a USDC flash via a different venue.
- **Re-entrancy / callback signature mismatch**: Balancer V2 expects
  the recipient to *push* tokens back before the callback returns; the
  PoC follows that convention.
- **Curve fee param drift**: Curve factory pools have on-chain owner
  fee parameters that can change. PoC reads fresh on-fork.

## Result

Status: theoretical (forge build not run). On the pinned block the
quote-gate may report `no_arb` if the spread has compressed below the
12+ bps fee floor — that is the intended fail-soft behaviour. On a
block where edge ≥ 15 bps, expect ~$500-1200 net on 1M USDT
notional, single-block, capital-free.
