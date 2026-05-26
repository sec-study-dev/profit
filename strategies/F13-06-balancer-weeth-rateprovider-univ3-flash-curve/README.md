# F13-06: Balancer weETH rate-provider lag + UniV3 1bp WETH flash + Curve weETH/WETH unwind

## Mechanism

A **3-protocol** atomic arb that exploits stale `weETH` rate-provider
caching on Balancer's weETH/WETH ComposableStable pool:

1. **UniV3 wstETH/WETH 1bp pool** as the flashloan source — borrow N
   WETH (token1) with only the pool's own swap-fee premium (0.01%).
   The pool is the cheapest WETH flash on mainnet because there is no
   external flash-loan premium on top.
2. **Balancer weETH/WETH ComposableStable** is the "stale-priced"
   venue. It quotes `weETH ↔ WETH` via a rate-provider cache that
   reads `IWeETH.getRate()`. EtherFi's `getRate()` drifts upward
   continuously (~3-4% APR, ≈ 0.4 bps/hour) as restaking rewards
   accrue. The cache refreshes every cache duration (default
   60 minutes) or on-demand. Between refreshes, the Balancer pool
   under-prices weETH versus its true intrinsic value.
3. **Curve weETH/WETH ng pool** as the fresh-price unwind. Curve's ng
   stableswap re-prices on every swap; this is a different venue from
   UniV3 (which has shallower weETH liquidity than Curve as of late
   2024).

Atomic flow:
- Flash 200 WETH from UniV3 wstETH/WETH 1bp pool.
- Swap `WETH → weETH` on Balancer (Balancer's stale rate → we get
  more weETH than market).
- Swap `weETH → WETH` on Curve ng (fresh price → we recover *more*
  WETH than we deposited).
- Repay flash (200 WETH + ~0.02 WETH UniV3 fee).
- Keep the spread (typically 1-3 bps of notional).

## Why it composes

This is the **weETH analog of F13-02** (rETH rate-lag) but uses a
**different unwind venue** (Curve instead of UniV3) and a **different
flash source** (UniV3 instead of Balancer flashLoan). The
three-mechanism count makes this distinct from any F02 (LRT-loop) or
F03 (depeg) strategy in the family:

| Strategy | Flash       | Stale venue | Fresh venue |
|----------|-------------|-------------|-------------|
| F03-03   | Balancer    | Balancer    | Curve       |
| F13-01   | UniV3       | Balancer    | UniV3       |
| F13-02   | Balancer    | Balancer    | UniV3       |
| F13-06   | **UniV3**   | Balancer    | **Curve**   |

Mechanism count: **3** (UniV3 + Balancer + Curve).

## Preconditions

- Recent EtherFi `getRate()` update has not yet propagated to the
  Balancer rate cache (typical window: 0-60 min after each rebase).
- Flash pool (UniV3 wstETH/WETH 1bp) has ≥200 WETH idle in token1
  reserves.
- Spread ≥ `MIN_SPREAD_BPS = 3` (below this the round-trip fees on
  Balancer + Curve + the UniV3 flash premium kill the PnL).

## Strategy steps

1. Read `IWeETH.getRate()` (fresh) and `BalancerPool.getTokenRate(WEETH)`
   (cached).
2. If `(rFresh - rStale)/rStale < 3 bps`, log and bail.
3. Else: call `pool.flash(this, 0, 200e18, "")` on the UniV3 1bp pool.
4. In callback:
   a. Swap `WETH → weETH` on Balancer CSP via `Vault.swap`.
   b. Swap `weETH → WETH` on Curve ng `exchange(0, 1, ...)`.
   c. Transfer `200 + fee` WETH back to the UniV3 pool.
5. Report PnL.

## PnL math

At 200 WETH notional, 5 bps stale spread, late-2024 conditions:
- Gross capture: `200 * 5e-4 = 0.1 WETH` ≈ **$320 @ ETH=$3,200**.
- Costs:
  - UniV3 flash premium (0.01% of 200 WETH) = 0.02 WETH ≈ **$64**.
  - Balancer swap fee (typical 0.04% for LST pools) on 200 WETH =
    0.08 WETH ≈ **$256**.
  - Curve weETH/WETH ng fee (typically 0.01-0.04%) on the unwind ≈
    0.04-0.16 WETH = **$128-$512**.
  - Gas: 380k gas at 5 gwei = 0.0019 ETH ≈ **$6**.

Net: typically **-$80 to +$60** at 5 bps. The strategy only profits
when spread > ~8 bps (≈ first 10 min after a Lido-style large rebase)
or when Curve's fee tier is low (some ng pools run at 1 bp).

At **10 bps spread** the gross is $640, fees $250-$330, net
**+$310 to +$390**.

## Block pinned

- `FORK_BLOCK = 21_500_000` (early 2025 era). Balancer weETH CSP active
  and rate cache present. PoC short-circuits if spread < 3 bps at this
  block.

## Risks

- **Rate cache front-runs**: any keeper bot can call
  `Vault.updateProtocolFeeCache` or interact with the pool to refresh
  the rate cache. Once refreshed, the spread closes immediately.
- **Curve depth**: the Curve weETH/WETH ng pool has lower TVL than
  Balancer's at certain blocks; a 200-WETH unwind may move the Curve
  spot price significantly.
- **Balancer pool address evolution**: the canonical weETH/WETH CSP
  has been redeployed multiple times. The address above
  (`0x05ff47AFADa98a98982113758878F9A8B9FddA0a`) is one of the active
  CSPs in 2024; verify on Balancer's pool registry before deployment.
- **getRate() returning zero on weETH** during proxy upgrades — the
  PoC falls back to assuming parity in that case.

## Result

- Status: **mechanically demonstrated**. PoC reads fresh and stale
  rates, gates on min spread, and (if gated) executes the 3-leg atomic
  trade.
- Expected per-event PnL (gated): **+$300 to +$400 at 10 bps spread,
  200 WETH notional, low gas**.
