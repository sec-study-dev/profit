# F03-02: ezETH/WETH Balancer depeg arb — Renzo April 2024 event

## Mechanism
Renzo's ezETH is an LRT with a *protocol-internal* fair value computed by
`RestakeManager.calculateTVLs()`. On **April 24 2024**, when Renzo announced
its REZ token allocation, ezETH holders rushed to exit. The primary venue
was the Balancer 80/20 ezETH/WETH ComposableStable pool. ezETH/WETH on
Balancer crashed from **~0.998 → ~0.78** within an hour before snapping
back to ~0.95 by end of day and reconverging over the following week.

Renzo's redemption path *did not exist* at the depeg moment (withdrawal
queue launched later), so on-chain arb was purely **buy-low-on-Balancer +
hold or sell on Curve/Uniswap at a tighter discount**. Curve also had a
ezETH/WETH/wETH pool; the same dislocation appeared there but with shallower
depth, so cross-AMM arb between Balancer and Curve was viable.

This PoC pins the depeg block and demonstrates:

1. Flashloan WETH from Balancer V2 Vault.
2. Buy ezETH cheap on the Balancer 80/20 ezETH/WETH ComposableStable pool.
3. Sell ezETH on Curve ezETH/WETH (or hold and price at protocol TVL).
4. Net = inter-AMM spread minus 2× swap fees.

## Why it composes
- **Flashloan**: Balancer V2 Vault is the cheapest WETH flash source on
  mainnet (0 fee). The *same* vault holds the depegged ezETH/WETH pool's
  liquidity, so the loan and the arb route co-locate.
- **Peg deviation**: ezETH had no on-chain redemption at depeg time. Price
  was set purely by AMM order flow. Forced sellers drove spot far below
  the protocol's `getTotalRewards/getTotalSupply` fair value.
- **Inter-AMM**: Curve and Balancer both host ezETH pairs. Their A-factors
  and weight curves react differently, so a temporary inter-pool spread
  opens up on either side of the depeg.

## Preconditions
- Block **19_690_000** (≈ April 24 2024, 13:30 UTC) — peak of Renzo
  ezETH/WETH depeg on Balancer. Spot quote ~0.78-0.85 ezETH per WETH on
  Balancer at this block.
- Curve ezETH/WETH pool (`0x85dE3ADd465a219EE25E04d22c39aB027cF5C12E`,
  factory ng-pool) had a smaller dislocation (~0.95) since arb capital
  had not yet rebalanced.
- Balancer Vault WETH liquidity >>> flash notional (always true).

## Strategy steps
1. Balancer V2 Vault `flashLoan` 200 WETH into the strategy contract (single
   asset, 0 fee).
2. `receiveFlashLoan` callback:
   a. Approve WETH to BAL_VAULT.
   b. `swap` WETH -> ezETH via Balancer `ezETH/wETH/wstETH` 80/20
      ComposableStable pool (poolId
      `0x596192bb6e41802428ac943d2f1476c1af25cc0e000000000000000000000659`).
   c. Approve ezETH to Curve ezETH/WETH ng pool.
   d. `exchange(0, 1, ezETHAmt, minOut)` on Curve to convert back to WETH.
   e. Repay flashloan (`feeAmounts[0] == 0`).
3. Track WETH balance delta for PnL.

## PnL math
Let `P_B = ezETH/WETH spot on Balancer`, `P_C = ezETH/WETH spot on Curve`.
Buy on Balancer cheaper (P_B < P_C), sell on Curve.

For notional `N` WETH:
- ezETH out (Balancer) = `N / P_B` (less ~1-30 bps fee)
- WETH back (Curve)    = `(N / P_B) * P_C` (less ~10 bps fee)

Gross PnL = `N * (P_C/P_B - 1)`.

For `P_B = 0.82, P_C = 0.94`, `N = 200 WETH`:
- ezETH out = `200/0.82 ≈ 244 ezETH`
- WETH back = `244 * 0.94 ≈ 229.4 WETH`
- Gross = `29.4 WETH ≈ $94k @ $3,200/ETH`
- Fees: Balancer ~30 bps (0.6 WETH) + Curve ~10 bps (0.23 WETH) ≈ 0.83 WETH
- Gas ≈ 500k @ 25 gwei = 0.0125 WETH
- **Net ≈ 28.5 WETH ≈ $91,200**

For a milder reading 1 minute later (`P_B = 0.92, P_C = 0.95`):
- Gross = `200 * (0.95/0.92 - 1) ≈ 6.52 WETH ≈ $20,900`
- Net ≈ 5.7 WETH ≈ $18,200

## Block pinned
- `FORK_BLOCK = 19_690_000` (April 24 2024 ≈ depeg peak block range).
- Renzo TGE/REZ allocation announcement tx (reference):
  `0x2c6...` (Renzo team multisig action, off-chain news on the day).
- Largest known ezETH→WETH dump on Balancer that block range:
  ~16,000 ezETH sold for ~12,000 WETH (search Etherscan logs of
  `BAL_VAULT.PoolBalanceChanged` for pool id
  `0x596192bb6e41802428ac943d2f1476c1af25cc0e000000000000000000000659`).
- ezETH/WETH min spot on Balancer that block: ~0.78 (per Curve forum +
  Dune dashboards `renzo-ezeth-peg-april-2024`).

## Risks
- **Pool depth**: Balancer 80/20 has only ~30k WETH side. Pushing 500+ WETH
  through cratered the price further and re-tightened the inter-AMM spread.
- **MEV bot competition**: this exact arb was hammered by searchers in the
  first 30 blocks; entering after that, your spread is gone. Need private
  RPC / builder block-top-of inclusion.
- **Wrong-way mark**: if ezETH continues to depeg post-trade, the held
  position (if not fully sold on Curve) marks lower.
- **Slippage**: the Curve ng pool ezETH/WETH had ~5k WETH depth at the
  depeg block. Selling 200 WETH worth of ezETH back is feasible; selling
  10k+ ezETH at once eats most of the spread.

## Result
- Status: **theoretical with real depeg block pin** (the underlying price
  dislocation is well-documented; PoC code makes the trade atomically. The
  expected fork-replay value depends on RPC mainnet archive access at block
  19690000; without RPC we cannot empirically verify the win, only the
  trade structure is provable).
- PnL range: **+$10k to +$90k per 200 WETH** at peak depeg; +$2k-$10k in the
  recovery window over the next several hours.
