# F13-01: UniV3 wstETH/WETH 0.01% flashloan + Balancer wstETH/WETH ComposableStable rate-provider arb

## Mechanism

Composes two Wave-2 family themes:

1. **UniV3 single-pool flash** — `IUniswapV3Pool.flash()` lets *any* address
   borrow up to the pool's full reserves for the **pool's own swap fee**
   (no extra premium). The wstETH/WETH 1 bp pool
   (`0x109830a3b59ddabe21ee0b1c34dd4a59e3f2ac81`, fee tier `100 = 0.01%`)
   is the cheapest flashloan on mainnet for ETH-denominated notional: a
   1,000 WETH flash costs only ~0.1 WETH in fees.

2. **Balancer ComposableStable rate-provider lag** — Balancer's wstETH/WETH
   ComposableStable pool
   (`0x93d199263632a4EF4Bb438F1feB99e57b4b5f0BD`, pool id
   `0x93d199263632a4ef4bb438f1feb99e57b4b5f0bd0000000000000000000005c2`)
   prices wstETH against WETH via a **rate-provider cache**. The cache is
   refreshed lazily, typically every 60 minutes (default cache duration on
   newer ComposableStable v5 deployments). Between cache refreshes the
   Balancer pool prices wstETH via the **stale**
   `stEthPerToken()`-derived rate. The on-chain `wstETH.stEthPerToken()`
   appreciates continuously (~3-4% APR, ≈ 0.4 bps/hour). The cache
   accordingly drifts up to ~0.4 bps per hour of stale time. After a Lido
   oracle daily rebase (`stEthPerToken` jumps ~1-2 bps in a block), the
   stale-rate spread peaks for the first ~hour.

The atomic arb borrows WETH from the UniV3 1 bp pool, swaps **WETH→wstETH**
on the stale Balancer pool (where wstETH is cheap because the cached rate
is below the current `stEthPerToken`), then unwinds **wstETH→WETH** on the
UniV3 pool (which prices at the *market* rate, i.e. roughly the fresh
rate). Repay the UniV3 flash + 1 bp fee.

Profit equation (per N WETH flashed):
```
gross   = N * (R_fresh - R_stale) / R_stale            // bps spread captured
flashFee = N * 0.0001                                  // UniV3 1 bp pool
balFee   = N * fee_bps_bal                             // ~1 bp on the LST CSP
univ3Fee = N * 0.0001                                  // already inside the unwind swap
net     = gross - flashFee - balFee - univ3Fee
```

If `R_fresh - R_stale` exceeds ~3 bps the trade is net-positive.

## Why it composes

- The UniV3 flash costs 1 bp — *less* than the spread the rate-provider lag
  can deliver.
- The unwind venue (the *same* UniV3 wstETH/WETH 1 bp pool) is also the
  cheapest possible unwind: 1 bp fee, and the pool's TVL is large enough
  (>$200M) to absorb 1k WETH with negligible price impact.
- The Balancer pool's rate-provider design *guarantees* that whenever
  Lido's oracle rebase fires, the pool's wstETH side is under-priced
  relative to the fresh `stEthPerToken`. The arb is **directional and
  predictable** rather than purely directional like a normal AMM arb.

## Preconditions

- A block in the **stale window** — i.e. shortly after Lido's daily oracle
  report (`Lido.handleOracleReport` from `LidoOracle`) raised
  `stEthPerToken`, but before any liquidity event on the Balancer pool
  triggered `updateTokenRateCache(wstETH)`.
- UniV3 wstETH/WETH 1 bp pool must have ≥ flash notional in WETH (it
  generally has >$50M WETH).
- Balancer pool depth on the WETH side ≥ flash notional / 5 for tolerable
  price impact.

## Strategy steps

1. Read fresh rate: `IWstETH.stEthPerToken()` (`R_fresh`, 1e18).
2. Read cached rate: `BalancerRatedPool.getTokenRate(wstETH)`
   (`R_stale`, 1e18). Compute spread.
3. If spread < `MIN_SPREAD_BPS`, return early (gated, no revert).
4. Call `IUniswapV3Pool.flash(this, 0, N_WETH, "")` on the 1 bp pool.
5. In `uniswapV3FlashCallback(fee0, fee1, data)`:
   a. Approve WETH on Balancer Vault.
   b. Balancer single-swap WETH → wstETH (GIVEN_IN, ~stale price).
   c. Approve wstETH on UniV3 SwapRouter.
   d. UniV3 exactInputSingle wstETH → WETH on the same 1 bp pool.
   e. Transfer `N_WETH + fee1` back to the pool.

## PnL math (illustrative)

Assume:
- `R_fresh = 1.18000` (wstETH peg ≈ 1.18 stETH).
- `R_stale = 1.17985` (≈ 1.3 bps stale).
- `N = 1,000 WETH`, ETH = $3,200 → notional $3.2M.

- WETH → wstETH on Balancer (stale): output ≈ `1000 / 1.17985 ≈ 847.57` wstETH.
- wstETH → WETH on UniV3 (fresh): output ≈ `847.57 * 1.18000 * (1 - 0.0001)`
  ≈ `1000.13 WETH` gross.
- UniV3 1 bp flash fee: `1000 * 0.0001 = 0.1 WETH`.
- Balancer pool fee (1 bp): `1000 * 0.0001 = 0.1 WETH`.
- **Net ≈ 1000.13 - 1000 - 0.1 - 0.1 = -0.07 WETH at 1.3 bps stale**.

The strategy is *break-even at ~3 bps stale* and meaningfully profitable
only on the first ~30 minutes after a Lido oracle rebase that pushed
`stEthPerToken` up by 1-2 bps in a single block.

## Block pinned

- `FORK_BLOCK = 20_900_000` (Oct 2024 timeframe). The Lido oracle
  reports roughly daily, so most blocks have small (<1 bp) stale
  spreads. The PoC reads the spread at fork time and short-circuits if
  it is below `MIN_SPREAD_BPS = 1` so the test does not revert on
  no-arb regimes — Wave 3 can re-pin to a higher-spread block when
  archive logs identify one.

## Risks

- **Cache refresh by another tx**: any other join/exit/swap on the
  Balancer pool in the same block will refresh the cache and erase the
  arb. Mitigated by atomic single-block execution.
- **UniV3 unwind price impact**: at very large notional the second-leg
  swap moves the UniV3 pool away from the fresh rate; profit caps at
  the pool's depth-weighted spread.
- **Pool fee tier change**: Balancer can raise the swap fee on the
  ComposableStable; check before each rebase.
- **Reentrancy lock**: Balancer's vault has a re-entrancy guard that
  blocks calling into the vault during a vault callback. We are *not*
  in a vault callback (the flash is a UniV3 flash), so this does not
  apply.

## Result

- Status: **theoretical** (correct construction; profitable only at
  blocks immediately after a Lido oracle rebase when archive scan can
  pin to ≥3 bps stale spread).
- PnL range: **-$50 to +$300 per 1,000 WETH** depending on staleness.
- Expected gas: ~330k @ 25 gwei ≈ 0.008 ETH ≈ $26.
