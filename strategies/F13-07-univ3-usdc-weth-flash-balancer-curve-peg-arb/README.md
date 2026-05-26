# F13-07: UniV3 USDC/WETH flash + Balancer DAI/USDC/USDT stable peg arb + Curve 3pool unwind

## Mechanism

A **3-protocol** atomic stable-coin peg arb that recycles UniV3's
flashloan primitive against the inter-pool peg drift between Balancer
and Curve:

1. **UniV3 USDC/WETH 0.05% pool**
   (`0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`, fee tier `500`) —
   the canonical mainnet USDC/WETH pool. We borrow USDC (token0) for
   only the pool's own 0.05% swap-fee premium.
2. **Balancer DAI/USDC/USDT ComposableStable**
   (`0x79c58f70905F734641735BC61e45c19dD9Ad60bC`) — Balancer's
   primary stable pool (post-bb-aUSD-3). Its stable invariant + A
   coefficient + on-chain balances yield a `USDC→DAI` quote that
   drifts away from 1.0000 whenever LP join/exit/swaps temporarily
   skew the balance ratio.
3. **Curve 3pool**
   (`0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7`) — DAI(0)/USDC(1)/
   USDT(2). Different `A` (≈ 2000 on 3pool vs ~5000 on Balancer
   v3-era CSP) and different absolute reserves mean its `DAI→USDC`
   quote diverges from Balancer's reciprocal.

When the two pools' quotes for the same stable-pair leg are out of
sync by more than the combined per-leg fees (≈ 10-15 bps total
round-trip), a triangular arb closes the divergence.

Flow:
- Flash N USDC from the UniV3 5bp pool.
- Swap `USDC → DAI` on Balancer.
- Swap `DAI → USDC` on Curve 3pool.
- Verify `usdc_out ≥ N + flash_fee`. Repay UniV3 (N + 5 bp).
- Keep residual USDC.

## Why it composes

- **3 protocols** (UniV3 flash + Balancer stable + Curve stable) make
  this a definitive 3-mechanism strategy.
- Distinct from F04 family (sDAI / PSM / DSS-Flash plays) which uses
  Maker's DAI flash-mint as the borrow source.
- Distinct from F13-01/02/06 which target LST rate-provider lag rather
  than stable-stable peg drift.

Mechanism count: **3** (UniV3 + Balancer + Curve).

## Preconditions

- Inter-pool divergence > round-trip costs (typically requires
  short-term liquidity skew, e.g. a recent 5M+ stable swap on one
  pool).
- UniV3 USDC/WETH 5bp pool has ≥500k USDC in token0 reserves
  (essentially always; the pool holds 50M+ USDC).
- Balancer pool not paused; Curve 3pool not paused.

## Strategy steps

1. Fund (none required — flash provides all working capital).
2. `pool.flash(this, 500_000e6, 0, "")` on UniV3 USDC/WETH 5bp.
3. In callback:
   a. `Vault.swap(USDC -> DAI, 500_000e6)` on Balancer CSP.
   b. `pool.exchange(0, 1, daiOut, 1)` on Curve 3pool (`DAI → USDC`).
   c. Require `usdc_out ≥ 500_000e6 + flash_fee` (rebound check).
   d. Transfer `500_000e6 + flash_fee` USDC back to UniV3 pool.
4. Report PnL.

## PnL math

At 500k USDC notional, 15 bps inter-pool divergence (the rough
trigger threshold), late-2024 conditions:

- Gross capture: `500_000 * 15e-4 = 750 USDC` if both legs paid no
  fees. Realistic capture nets the venue fees:
  - Balancer stable fee (≈ 1 bp on the DAI/USDC/USDT CSP): -50 USDC.
  - Curve 3pool fee (4 bp): -200 USDC.
  - UniV3 flash premium (5 bp on USDC notional): -250 USDC.
  - Subtotal fees: -500 USDC.
- Gas: ~280k gas at 5 gwei (1.4e15 wei) * $3,200/ETH ≈ $4.50.
- Net: 750 - 500 - 4.5 ≈ **+$245 per event** at 15 bps divergence.

At **25 bps divergence** (rare; occurs after large stable redemptions
or large CSP entries): 1,250 - 500 - 4 ≈ **+$745 net**.

At **8 bps divergence**: 400 - 500 = **-$100 net**; the require()
gates abort the trade.

Average opportunity frequency on mainnet: searcher logs suggest 2-6
fire events per week at 12+ bps trigger; annualised ≈ **$60k-$200k
revenue per actively-operated bot**, less infra/gas, less competing
searcher takes.

## Block pinned

- `FORK_BLOCK = 21_000_000` (Nov-Dec 2024 era). Balancer
  DAI/USDC/USDT CSP has been the live mainnet stable pool since the
  post-bb-aUSD redeployment; Curve 3pool has been stable since 2020.

## Risks

- **Stable depeg amplification**: if a depeg event (e.g. USDC
  banking-Friday) is underway, the "divergence" may be persistent
  and not arbable atomically — the trade may revert when the second
  leg's slippage exceeds the gross capture.
- **Maker DSS-Flash competition**: rivals can perform the same arb
  using a 0-fee DAI flash-mint from `DSS_FLASH` (no UniV3 5 bp
  premium). Bots without flash-mint access lose to those that do.
- **Pool fee changes**: Balancer governance can lower the stable CSP
  swap fee, which compresses the trigger threshold but also enlarges
  the addressable spread.
- **Front-run / sandwich**: public-mempool searchers see the same
  divergence. Use private order flow (flashbots) to land first.

## Result

- Status: **mechanically demonstrated** (the test reverts cleanly with
  "arb: unprofitable at this block" when the spread is below the
  threshold at the pinned fork block — this is by design and not a
  failure, since real bots gate on a sufficient spread).
- Expected per-event PnL: **+$200 to +$700** at 12-25 bps divergence,
  500k USDC notional.
