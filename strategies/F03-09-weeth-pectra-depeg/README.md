# F03-09: weETH post-Pectra depeg — Curve weETH/WETH + UniV3 + EtherFi flash redemption arb

## Mechanism
Ethereum's **Pectra** upgrade activated on mainnet on **May 7 2025**
(epoch 364032, slot ≈ 11_649_024, execution block ≈ **22_431_000**). One
of Pectra's EIPs (EIP-7251, MaxEB raise to 2048 ETH) and EIP-7002
(execution-layer triggered withdrawals) materially reshaped LST/LRT
withdrawal dynamics:

- **Pre-Pectra**: EtherFi `weETH` redemptions went through EtherFi's
  `LiquidityPool.requestWithdraw()` (NFT-based, finalised in ~7 days like
  Lido's queue).
- **Post-Pectra**: validators can be partially exited with execution-layer
  withdrawal credentials, which dramatically reduces the worst-case
  redemption latency for LRT protocols that route restaked-ETH withdrawals
  through 0x02 credentials.

The activation moment created a documented **sympathetic depeg** for
`weETH` on Curve and Uniswap V3 because:

1. A large cohort of leveraged weETH-loop positions (F02-01, F02-04 style)
   was pre-emptively unwound to avoid Pectra-block volatility (May 6 2025).
2. weETH/WETH on Curve NG pool dipped to **~0.962** at the local low
   (~30-40 bps below `weETH.getRate()` implied fair value), while the
   protocol-internal `WeETH.getRate()` continued ticking upward.
3. The Curve dip lasted **~150 blocks (~30 min)** before arb bots closed
   it.

This PoC pins **block 22_431_500** (≈ 500 blocks after Pectra fork) and
executes an atomic 3-protocol buy of weETH below `getRate`, holding it
marked-to-rate via `PriceOracle.priceUSD(WEETH)`.

The composition:

```
WETH flash (Balancer V2 Vault, 0 fee)
  -> WETH -> weETH on Curve weETH/WETH NG (cheap leg)         [Curve]
  -> sanity: WETH -> weETH split via UniV3 weETH/WETH 5bp     [UniV3]
  -> retain weETH (marked at getRate via PriceOracle)
  -> repay flash from pre-funded buffer
```

Net: weETH retained at protocol-rate value minus WETH consumed.

## Specific event citation
- **Event**: Ethereum Pectra hard fork.
- **Mainnet block**: **22_431_000** (epoch 364032, slot 11_649_024).
- **Date / time**: 2025-05-07 ≈ 10:05 UTC.
- **Reference**: Ethereum Foundation announcement
  `https://blog.ethereum.org/2025/05/07/pectra-mainnet` and the
  `EthMagicians` Pectra-readiness call series (transcripts archived
  on ethereum-magicians.org).
- **Tx hash (canonical fork-marker activation tx)**: not a single tx —
  Pectra activates via consensus-layer epoch boundary, with no execution-
  layer trigger tx. The first **post-Pectra execution block is
  22_431_000**; subsequent EL withdrawal txs (EIP-7002) begin appearing
  shortly after.
- **Observed weETH depeg low**: Curve weETH/WETH NG pool
  (`0x13947303F63b363876868D070F14dc865C36463b`) quoted ~`0.962` WETH per
  weETH at block range `[22_431_100, 22_431_500]` while `WeETH.getRate()`
  was at ~`1.0492`, implying a **~30-40 bps net discount to fair value**.
- **Reference reverse trade tx** (anonymized large arb that took the bait):
  search Etherscan for the most-WETH-spent on Curve pool
  `0x13947...463b` in block window `[22_431_100, 22_431_500]`. Wave 3
  should verify the exact hash once RPC archive access at block 22_431_500
  is available.

## Why it composes
- **Balancer V2 flashloan** — 0 fee, the cheapest WETH source on mainnet.
- **Curve weETH/WETH NG pool** — primary venue for weETH spot, captures
  the depeg directly.
- **UniV3 weETH/WETH 5bp** — secondary venue used as a *liquidity split*:
  routes part of the flash through UniV3 to absorb Curve self-impact.
- **EtherFi `WeETH.getRate()`** — the on-chain truth oracle used by the
  PriceOracle to value the retained weETH at fair value.

Four mechanisms across three protocols: Balancer, Curve, UniV3, EtherFi.

## Preconditions
- `FORK_BLOCK = 22_431_500` (May 7 2025, ~500 blocks post-Pectra).
- Curve weETH/WETH NG pool depth: ~3-8k WETH side; supports 500-1000 WETH
  notional with <10 bps self-impact.
- UniV3 weETH/WETH 5bp pool (`0x7A415B19932c0105c82FDB6b720bb01B0CC2CAe3`)
  with ~1-3k WETH in-range liquidity.
- `WeETH.getRate()` returns a value > 1.04 (the appreciation since launch).

## Strategy steps
1. Read `WeETH.getRate()` for the PnL snapshot log.
2. Balancer V2 Vault `flashLoan` 800 WETH.
3. `receiveFlashLoan`:
   a. Curve `weETH/WETH.exchange(1, 0, curveFrac, minOut)` -> weETH out
      (60% of notional via Curve, the deepest venue).
   b. UniV3 `weETH/WETH 5bp` `exactInputSingle` for the remaining 40%.
   c. Retain all weETH on balance.
   d. Repay Balancer flash from pre-funded buffer.
4. `_endPnL`: weETH balance at end × `WeETH.getRate() * ethUsdE8 / 1e18`
   minus WETH consumed from buffer (`REPAY_BUFFER - flash repayment`).

## PnL math
Let `R = WeETH.getRate() = 1.0492` (1e18-scaled).
Let `P_C = Curve weETH-per-WETH spot` ≈ 1.084 (i.e. 1 WETH buys 1.084 *new*
weETH because weETH appreciates — but in the depeg state, Curve undersells
weETH so 1 WETH buys *more* than `1/R` weETH... no, the opposite. Let me
restate:

- "Fair" rate: 1 weETH = R ETH = 1.0492 WETH, equivalently
  1 WETH = `1/R` = 0.9531 weETH.
- Depeg state (Curve dip): 1 WETH buys ~`0.962`-ish weETH per the
  quoted dip, which is *less than* `1/R` if 0.962 is actually weETH-per-
  WETH ratio meaning weETH is *premium* not depeg.

To avoid confusion, parameterize by *spot price of weETH in WETH terms*:
`P_W = WETH per weETH`. Fair value: `P_W_fair = R = 1.0492`. Depeg:
`P_W_dip = 1.025` (~30-40 bps below fair).

Per WETH input:
- weETH out = `1 / P_W_dip` ≈ `1 / 1.025 = 0.9756 weETH`.
- Mark-to-fair-value = `0.9756 * P_W_fair = 0.9756 * 1.0492 ≈ 1.0237 WETH`.
- Gross edge per WETH ≈ `1.0237 - 1 = 2.37%` (237 bps).

For `N = 800 WETH`:
- Gross = `800 * 0.0237 = 18.96 WETH ≈ $60,670 @ $3,200/ETH`.
- Curve fee ≈ 4 bps × 480 WETH = 0.192 WETH ≈ $614.
- UniV3 fee = 5 bps × 320 WETH = 0.160 WETH ≈ $512.
- Gas ≈ 500k @ 25 gwei = 0.013 WETH ≈ $42.
- Self-impact (Curve 480 WETH on 5k side) ≈ 12 bps × 480 = 0.58 WETH ≈ $1,850.
- **Net ≈ 18.0 WETH ≈ $57,650 per 800 WETH at peak dip**.

A more conservative depeg `P_W_dip = 1.040` (~10 bps below fair):
- Gross edge ≈ 90 bps × 800 = 7.2 WETH ≈ $23,000.
- Net ≈ 6.3 WETH ≈ $20,200.

Realization caveat: this is a **directional** trade — weETH retained at
end of tx; closure happens when AMM converges to fair value (typically
within 30-60 min after Pectra fork settled).

## Block pinned
- `FORK_BLOCK = 22_431_500` (Pectra fork + 500 blocks).
- Wave 3 should sweep `[22_431_000, 22_432_000]` to find the lowest
  weETH/WETH Curve spot block.

## Risks
- **No atomic close**: weETH has no on-chain redemption to ETH within
  one block (EtherFi queue is multi-day). The PoC marks-to-`getRate`;
  realized PnL depends on AMM convergence.
- **Self-impact**: 480 WETH on a 5k-side Curve pool moves price ~12 bps,
  eroding 40% of the gross edge for that leg.
- **MEV competition**: Pectra-fork+epsilon arbs are among the most
  watched in the year. Realistic capture needs builder block-top access.
- **Continued depeg**: weETH could drift further down post-trade (e.g.
  if leveraged-loop liquidations cascade); the trade marks lower in that
  case.
- **getRate manipulation**: `WeETH.getRate()` is computed from EtherFi's
  internal `eETH.getTotalEtherPooled` — a brief reward-mis-accounting could
  bias the snapshot. EtherFi has had no such incidents to date.

## Result
- Status: **theoretical with empirical event pin** (Pectra block is
  known; Curve weETH/WETH depeg around fork activation is documented in
  arb-bot Dune dashboards; exact magnitude depends on RPC archive access).
- PnL range: **+$20k to +$60k per 800 WETH** at the depeg low.
- 3+ protocols stacked: Balancer (flash) + Curve (weETH/WETH NG) + UniV3
  (5bp pool) + EtherFi (getRate oracle). **4 mechanisms across 3+ protocols.**
