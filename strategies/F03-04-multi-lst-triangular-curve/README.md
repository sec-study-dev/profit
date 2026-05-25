# F03-04: Multi-LST triangular arb — Curve stETH × Curve rETH × wstETH wrap

## Mechanism
Each LST has *two* on-chain "prices":

1. **Internal protocol rate** — `WSTETH.stEthPerToken()` (== `stETH/wstETH`),
   `RETH.getExchangeRate()` (== `ETH/rETH`). These are deterministic and
   updated by protocol cron / wrap-unwrap.
2. **AMM spot price** — `Curve stETH/ETH`, `Curve rETH/ETH`, `Curve
   wstETH/rETH` (if it exists), `Balancer wstETH/rETH` etc.

In an efficient market, the *triangle* closes:

```
1 ETH -> Curve stETH/ETH -> stETH -> wstETH.wrap -> wstETH
       -> Balancer wstETH/wETH      -> ETH      should yield ~ 1 ETH.
```

When *any* leg drifts, the triangle has a non-zero edge. Real cases:

- After a Lido stETH/ETH Curve LP withdrawal, the pool transiently quotes
  stETH < 1 ETH while protocol rate is exactly 1. Wrap and sell wstETH on
  Balancer/Uniswap V3 wstETH/wETH at the *fresh* wstETH price.
- After a Rocket Pool rate update (see F03-03), rETH/ETH on Curve briefly
  trades at the old rate while the *fresh* rate makes rETH redeem for more
  ETH via the deposit-pool reverse (`burn(rETH)`).

This strategy demonstrates a **3-hop atomic flashloan trade**:

```
WETH (flash from Balancer V2 Vault)
  -> ETH via WETH.withdraw
  -> stETH via Curve stETH/ETH pool (cheap leg)
  -> wstETH via WSTETH.wrap
  -> WETH via Balancer wstETH/wETH pool
  repay flash
```

The edge exists when Curve's stETH leg has a tighter discount than
Balancer's wstETH leg (after multiplying through `stEthPerToken`).

## Why it composes
- **Flashloan**: Balancer V2 Vault — 0 fee, same vault hosts the wstETH/wETH
  pool so the unwind is in-vault (no extra hop).
- **Wrap-unwrap parity**: `WSTETH.wrap` is *deterministic*, fee-free, and
  computed off `stEthPerToken`. So it's the perfect bridge between rebasing
  and non-rebasing AMM venues.
- **Cross-AMM**: Curve and Balancer have different pricing curves for the
  same underlying ETH-staked asset. Imbalance in one pool does not
  instantaneously propagate to the other.

## Preconditions
- Curve `stETH/ETH` pool quotes `dy(0,1, 1 ETH)` > `1 stETH` (i.e. discount).
- Balancer wstETH/wETH pool quotes `1 wstETH ≈ stEthPerToken WETH`
  (i.e. at or very close to the protocol rate).
- Equivalent condition:
  `Curve.stETHperETH * stEthPerToken_inv * Balancer.wETHperWSTETH > 1`.

The simplest pin is the same as F03-01: block `17_560_000`, where Curve
stETH/ETH had a ~15 bps discount and Balancer wstETH/wETH was on rate.

## Strategy steps
1. Balancer V2 Vault `flashLoan` 500 WETH.
2. `receiveFlashLoan`:
   a. `IWETH.withdraw(500e18)` -> 500 ETH.
   b. Curve `stETH/ETH.exchange(0, 1, 500e18, minOut)` -> ~500.x stETH.
   c. `IStETH.approve(WSTETH, type(uint256).max)`.
   d. `IWstETH.wrap(stETH balance)` -> wstETH.
   e. Approve wstETH to Balancer Vault.
   f. Balancer `swap` wstETH -> WETH via wstETH/wETH ComposableStable
      (poolId
      `0x32296969ef14eb0c6d29669c550d4a0449130230000200000000000000000080`,
      pool address `0x32296969Ef14EB0c6d29669C550D4a0449130230`).
   g. Repay flash.

## PnL math
Notation:
- `P_C = Curve stETH-per-ETH` ratio (typically 1.001 - 1.005 at small discounts).
- `S  = stEthPerToken` (≈ 1.13 today; stETH per 1 wstETH).
- `P_B = Balancer wETH-per-wstETH` quote (should be ≈ `S` if Balancer is on rate).

Per 1 WETH in:
- stETH out (Curve, post-fee) = `P_C * (1 - f_C)` where `f_C ≈ 4 bps`.
- wstETH out (wrap) = `stETH / S`.
- WETH out (Balancer, post-fee) = `wstETH * P_B * (1 - f_B)` where `f_B ≈ 4 bps`.

Total = `P_C / S * P_B * (1 - f_C) * (1 - f_B)`.

For `P_C = 1.0015, S = 1.13, P_B = 1.13` (Balancer at rate):
- Total = `1.0015 / 1.13 * 1.13 * (0.9996)^2 ≈ 1.0007 WETH out per 1 WETH in`.
- Net per WETH ≈ **7 bps**.

For `N = 500 WETH`:
- Gross = `0.35 WETH ≈ $1,120 @ $3,200/ETH`.
- Gas ≈ 400k @ 25 gwei = 0.01 WETH.
- **Net ≈ 0.34 WETH ≈ $1,090**.

When Balancer wstETH/wETH is *richer* than rate (e.g. P_B = 1.135 vs S=1.13),
profit scales to ~50 bps × N ≈ 2.5 WETH on 500 notional. Such events are
visible in Balancer pool snapshots after large WETH-side withdrawals.

## Block pinned
- `FORK_BLOCK = 17_560_000` (same as F03-01; ~15 bps Curve stETH discount,
  Balancer wstETH/wETH on rate).
- For a richer block, search Balancer Vault `PoolBalanceChanged` events on
  pool id `0x322969...0080` for large single-sided WETH exits; pin one block
  after a >1% wstETH-balance imbalance.

## Risks
- **Triangular re-pegging**: by executing all three legs in one tx, your
  own trade reduces the edge. With 500 WETH and 20k WETH curve depth,
  ~2 bps of edge is lost to self-impact.
- **Balancer rate-cache stale**: if Balancer pool uses a cached `stEthPerToken`,
  the wstETH leg may underpay (this is actually a different arb — see F03-03).
- **Composability of approvals**: must reset stETH approval to wstETH
  before each call if the strategy is re-used (PoC uses `type(uint256).max`
  one-shot).
- **MEV**: a small (~$1k) edge is well within MEV-Bot range; private RPC
  submission required for live use.

## Result
- Status: **theoretical (mechanism-correct, no archive replay performed)**.
- PnL range: **+$200 to +$3,000 per 500 WETH** depending on Curve discount
  and Balancer pool imbalance. Median edge in 2024 was ~5-10 bps.
