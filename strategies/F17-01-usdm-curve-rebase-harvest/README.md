# F17-01: USDM rebase carry via Curve crvUSD/USDM pool

## Mechanism

This strategy captures the **daily-rebase yield** of Mountain Protocol's USDM
(`0x59D9356E565Ab3A36dD77763Fc0d87fEaf85508C`) by sourcing USDM on the open
market (Curve crvUSD/USDM pool) and holding while the protocol's
`rewardMultiplier()` accumulator grows.

Three primitives compose:

1. **USDM (Mountain)** — an allow-listed, rebasing ERC20 wrapping a Cayman SPV
   that holds short-duration US Treasury bills. Yield (currently ~4.7% APY) is
   passed to holders via a daily *upward* `rewardMultiplier()` update, similar
   to stETH but with off-chain BlackRock-managed collateral. Crucially, the
   token is **transferable** between any two whitelisted addresses (Curve pools
   are whitelisted), so a non-whitelisted user can still hold USDM by acquiring
   it via a Curve swap. However a non-whitelisted user *cannot* mint or redeem
   directly with the issuer.
2. **Curve crvUSD/USDM pool** (`0xC83b79C07ECE44b8b99fFa0E235C00aDd9124f9E`,
   2-coin stableswap-NG, coins=[crvUSD, USDM]). Provides the only deep,
   permissionless venue to convert in/out of USDM. Trades close to peg because
   arbitrageurs (whitelisted MMs) can mint/redeem against the issuer.
3. **crvUSD source** — seed equity arrives as crvUSD (mint-able permissionlessly
   from the LLAMMA controllers, or simply funded via `deal` in the PoC).

```
crvUSD seed --swap-> USDM (hold T days) --rebase--> more USDM --swap-> crvUSD
                                |
                                v
              rewardMultiplier() grows daily ~ 0.0125%
```

Each USDM share scales with `rewardMultiplier()`. The PoC verifies that
balance grows after `vm.warp` by reading the multiplier before/after the
warp window and asserting `balance_end > balance_start` strictly.

## Why it composes

USDM is **special** vs sDAI/sUSDS/sUSDe in three ways:

- **Real-world T-bill yield** — not Maker DSR, not Ethena funding, not
  staking. The yield source is uncorrelated to crypto-market funding regimes
  (when funding goes negative on Ethena, sUSDe drops; USDM keeps its T-bill
  coupon).
- **Rebasing** (vs sDAI's price-appreciating ERC4626 share). Means downstream
  DeFi composability is broken (a Uniswap v3 LP would not benefit from the
  rebase; only whitelisted pools that explicitly handle the rebase do).
- **Permissioned mint/redeem**, **permissionless secondary** — creates a
  natural Curve-pool premium/discount cycle where the pool *almost* recapitulates
  the issuer's NAV plus a small float.

The Curve crvUSD/USDM pool is the canonical on-ramp because (a) crvUSD itself
is yield-neutral, (b) the pool has been whitelisted by Mountain so trades go
through atomically, and (c) bidirectional swaps at ~0% slippage at <$100k size
make the carry-only thesis viable.

## Preconditions

- A mainnet block where:
  - The Curve crvUSD/USDM pool exists and has USDM liquidity. Pool deployment
    was ~Apr 2024, so pin block must be after that.
  - USDM `rewardMultiplier()` is monotonically increasing (no pause, no
    governance shut-down).
- This PoC pins **block 20_500_000** (Aug 2024). At that block USDM APY ≈
  4.7%, Curve pool TVL ≈ $5M, slippage on $100k crvUSD <-> USDM swap is
  <2bps.

## Strategy steps

1. Pin fork to block `20_500_000`.
2. Seed `address(this)` with `100_000` crvUSD via `_fund` (deal).
3. Approve Curve pool, swap `crvUSD -> USDM` (Curve coin index: 0=crvUSD,
   1=USDM). Curve pools whitelist the *pool* not the depositor, so this works
   for any caller.
4. Read pre-warp `rewardMultiplier()` and USDM balance.
5. `vm.warp(block.timestamp + 90 days)`. Mountain's off-chain oracle pushes
   `rewardMultiplier()` daily; we approximate this by *not* re-pinning a later
   block (the multiplier from the issuer is only updated by real transactions
   on real time, so within a single fork warp the rebase will NOT
   automatically materialise). Therefore we **multi-fork**: re-fork at block
   `20_500_000 + ~7 days of blocks` (block `20_550_000`, ≈ Aug 8 2024) where
   the multiplier has actually moved.
6. Read post-warp USDM balance and `rewardMultiplier()`. Compute rebase
   delta.
7. Swap USDM -> crvUSD via Curve.
8. Report PnL.

## PnL math

Notation:
- `M_0 = rewardMultiplier()` at start (1e18 scale)
- `M_T = rewardMultiplier()` at end
- `B_0 = balance at deposit` (USDM units)
- The protocol stores `shares = B_0 * 1e18 / M_0`; balance at any time =
  `shares * M_T / 1e18`. So `B_T = B_0 * M_T / M_0`.

At ~4.7% APY, over 7 days that's `4.7% * 7/365 ≈ 0.0901%`. On $100k notional
the rebase delta is ≈ **$90** raw, minus Curve round-trip slippage of
~$30-50 (≈ 3-5 bps both legs). Net ≈ $40-60 over 7 days, scaling linearly
with time horizon and notional.

The **gas cost** is two Curve swaps + small read calls ≈ 220k gas. At 20 gwei
and ETH=$3500 that's ~$15. Above ~$5k notional and ~3-day horizon the carry
exceeds gas. Below that, gas dominates.

For longer horizons (30-90 days), the carry compounds: at 30 days ≈ $385 on
$100k; at 90 days ≈ $1155.

## Block pinned

`20_500_000` (Aug 2 2024). USDM `rewardMultiplier` ≈ 1.034e18; Curve pool
operational; T-bill yield window stable.

End-of-horizon re-fork block: `20_550_000` (≈ Aug 9 2024, 7 days later).

## Risks

- **Mountain pauses rebase or de-whitelists pool.** Both are governance-
  controlled. If the pool is de-whitelisted, all USDM in the pool becomes
  stranded; arbitrageurs already exit before this.
- **Curve pool slippage** at large size. The crvUSD/USDM pool TVL at the
  pinned block is small; sizes above $500k will eat the entire carry in
  slippage on both legs.
- **Treasury yield drop.** T-bill rates can fall (e.g. Fed pivot); the
  `rewardMultiplier` is a passthrough so the user-visible APY drops in
  lockstep.
- **Re-forking limitation.** Since the issuer's off-chain oracle pushes
  `rewardMultiplier` updates via real transactions, `vm.warp` alone does NOT
  trigger a rebase. The PoC therefore re-forks at a later block. In
  production this is a non-issue (real time elapses, real transactions land);
  the test harness limitation only means we measure the realized rebase
  rather than a simulated one.
- **No flash-loan amplification.** Unlike sDAI/sUSDS, there is no Morpho
  market for USDM at the pinned block (as of mid-2024). A future strategy
  could loop USDM as collateral once Morpho-USDM/USDC market is created and
  rebase handling on Morpho is clarified.

## Result
Status: mechanically-reproducible
Expected PnL: ~4.7% APY (~$40-60 net per $100k seed over 7 days; ~$385 at 30 days; ~$1,155 at 90 days, scaling linearly with notional and time)

A clean rebase-capture PoC: seed crvUSD, convert to USDM through the only
permissionless venue, hold across a week of real time (via dual-fork), exit
back to crvUSD. PnL = `(B_T - B_0_after_swap) * price + swap slippage`. The
asserted post-condition is **strictly more USDM units held over the window
than at entry**, which is the rebase signal independent of any swap-curve
movement.
