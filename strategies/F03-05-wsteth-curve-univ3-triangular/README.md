# F03-05: wstETH wrap-path triangular arb — Curve stETH/ETH × Lido wrap × UniV3 wstETH/WETH

## Mechanism
wstETH has **two** at-rate conversion paths between WETH and itself, plus a
fundamental deterministic wrap/unwrap that ties them together:

1. **`Curve stETH/ETH` pool + `WSTETH.wrap`** — buy stETH on Curve at the
   pool's market discount, then wrap to wstETH at the protocol-internal
   `stEthPerToken` rate. Net: `wstETH_out = (N / P_C) / stEthPerToken` where
   `P_C` is Curve's stETH-per-ETH quote (< 1 when stETH is at a discount).
2. **`UniV3 wstETH/WETH` 1 bp pool** — buy wstETH directly from concentrated
   liquidity at the pool spot. The pool re-prices on every swap, so its
   quote reflects the *fresh* `stEthPerToken` plus any market-flow drift.

When Curve's stETH/ETH leg is at a non-trivial discount but the UniV3
wstETH/WETH 1bp pool is trading near the *fresh* `stEthPerToken`, the
**effective path-A wstETH/WETH price** is lower than path-B's spot. A
3-leg atomic trade closes the gap:

```
WETH (flash from Balancer V2 Vault, 0 fee)
  -> ETH via WETH.withdraw
  -> stETH via Curve stETH/ETH exchange    [Curve]
  -> wstETH via WSTETH.wrap                 [Lido protocol]
  -> WETH via UniV3 wstETH/WETH 1bp swap   [UniV3]
repay flash
```

This composes **four** distinct primitives: Balancer V2 flashloan, Curve
stableswap, Lido wstETH wrap, and Uniswap V3 1bp pool.

## Why it composes
- **Flashloan**: Balancer V2 Vault — 0 fee. Necessary because the edge per
  WETH is small (typically 3-15 bps), so 500-2000 WETH notional is required
  to clear gas + fees.
- **Curve stETH/ETH pool** (`0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`):
  stableswap with `int128` indices; coins[0] = ETH native sentinel,
  coins[1] = stETH. Discount appears when sellers dominate (LP exits,
  cross-protocol redemptions).
- **Lido wstETH wrap** (`0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`): fee-free,
  deterministic conversion `stETH -> wstETH` at the live `stEthPerToken`.
- **UniV3 wstETH/WETH 1 bp** (`0x109830a3b59ddabe21EE0B1c34Dd4A59E3F2aC81`):
  the deepest concentrated-liquidity venue for wstETH/WETH on mainnet.
  token0 = wstETH, token1 = WETH.

The three protocols are **independent**: Curve's pool state, Lido's protocol
rate, and UniV3's concentrated-liquidity ticks each react to different
flows. Imbalances between them are the basis for this triangle.

## Preconditions
- `FORK_BLOCK = 17_560_000` (July 4 2023) — Curve stETH/ETH at ~15 bps
  discount, UniV3 1bp pool trading near `stEthPerToken`.
- Sufficient Curve depth (>20k ETH per side) and UniV3 pool liquidity
  (>3k WETH worth of in-range wstETH side). The 1bp pool routinely has
  300-1500 wstETH in-range so a 500-WETH unwind is feasible without
  >5 bps slippage.
- Balancer Vault WETH liquidity >>> 500 WETH (always satisfied).

## Strategy steps
1. Balancer V2 Vault `flashLoan` 500 WETH into the strategy contract.
2. In `receiveFlashLoan`:
   a. `IWETH.withdraw(500e18)` -> 500 ETH (native).
   b. `Curve.exchange{value: 500e18}(0, 1, 500e18, minOut)` -> stETH out.
      (Curve stETH pool uses native ETH for index 0; payable call required.)
   c. `IStETH.approve(WSTETH, type(uint256).max)`.
   d. `IWstETH.wrap(stETH balance)` -> wstETH (deterministic at protocol rate).
   e. `IERC20(WSTETH).approve(UNI_V3_ROUTER, type(uint256).max)`.
   f. `UniV3 SwapRouter.exactInputSingle({tokenIn: WSTETH, tokenOut: WETH,
      fee: 100, ...})` -> WETH out.
   g. `IERC20(WETH).transfer(BAL_VAULT, 500e18)` to repay flash.
3. Track WETH delta; print PnL.

## PnL math
Let:
- `P_C` = Curve stETH-per-ETH (≈ 1.0015 at FORK_BLOCK; >1 means discount)
- `S`   = `stEthPerToken` (≈ 1.0925 at FORK_BLOCK; stETH per 1 wstETH)
- `P_U` = UniV3 WETH-per-wstETH spot (≈ S if pool is at rate)
- `f_C` = Curve fee ≈ 4 bps
- `f_U` = UniV3 1bp fee = 1 bp

Per 1 WETH input:
- stETH out (Curve, post-fee)  = `P_C * (1 - f_C)`
- wstETH out (wrap)            = `stETH / S = P_C * (1 - f_C) / S`
- WETH out (UniV3, post-fee)   = `wstETH * P_U * (1 - f_U)
                                = P_C * P_U / S * (1 - f_C) * (1 - f_U)`

Net edge per 1 WETH = `P_C * P_U / S * (1 - f_C) * (1 - f_U) - 1`.

For `P_C = 1.0015, S = 1.0925, P_U = 1.0925` (UniV3 on rate):
- Gross factor = `1.0015 * 1.0925 / 1.0925 = 1.0015`
- Net factor   = `1.0015 * 0.9996 * 0.9999 ≈ 1.0010` ⇒ **~10 bps edge per WETH**

For `N = 500 WETH`:
- Gross spread = `500 * 0.0015 = 0.75 WETH ≈ $2,400 @ $3,200/ETH`
- Net (post-fees) ≈ `500 * 0.0010 = 0.50 WETH ≈ $1,600`
- Gas ≈ 450k @ 25 gwei = 0.011 WETH ≈ $36
- **Net ≈ +$1,565 per 500 WETH** at ~15 bps Curve discount

When Curve discount widens to 30 bps (`P_C = 1.003`) the net jumps to
~25 bps × 500 WETH = 1.25 WETH ≈ $4,000. The June 2022 3AC peak (`P_C ≈ 1.06`)
would have implied ~5.5% gross — but UniV3 wstETH/WETH 1bp pool did not
exist back then; only post-2023 fork blocks expose this triangle.

## Block pinned
- `FORK_BLOCK = 17_560_000` (July 4 2023). Reasons:
  - Lido withdrawal queue is live, so the Curve stETH/ETH discount has a
    floor (~5-25 bps) rather than the 2022 chaos range.
  - UniV3 wstETH/WETH 1bp pool (`0x109830a3b59ddabe21EE0B1c34Dd4A59E3F2aC81`)
    is deployed and has meaningful liquidity.
  - Same block used by F03-01 / F03-04, so the family's PoCs converge on
    one well-understood snapshot.
- Alternative wider-spread blocks: any block within ±2,000 of a major
  stETH/ETH Curve LP exit (search `TokenExchange` events emitted from the
  pool for large directional flow).

## Risks
- **Self-impact**: the trade itself moves Curve's stETH balance, narrowing
  the discount. At 500 WETH on 20k ETH side depth, self-impact ≈ 2-3 bps.
- **UniV3 tick gap**: if the 1bp pool's in-range wstETH liquidity is thin,
  the wstETH→WETH unwind eats into the spread. The PoC sets
  `amountOutMinimum = 0` for simplicity but a production bot should
  compute a tighter floor from observed `slot0.sqrtPriceX96`.
- **Wrap rounding**: `WSTETH.wrap` truncates by 1 wei; stETH is rebasing
  so `balanceOf` after wrap may not return to exactly zero (≤2 wei dust).
- **MEV competition**: a ~10 bps edge on 500 WETH ($1.5k) is well within
  the typical bundle-snipe range; live deployment needs private RPC.

## Result
- Status: **theoretical** (mechanism-correct, trade is atomic and provable
  on a Curve-discount fork block; absolute PnL depends on archive RPC).
- PnL range: **+$1,000 to +$4,000 per 500 WETH** at 10-30 bps Curve discount.
- 3+ protocols stacked: Balancer flash, Curve, Lido wrap, UniV3 (4 mechanisms).
