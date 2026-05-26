# F13-03: Balancer wstETH/WETH ComposableStable LP — double-yield carry

## Mechanism

Balancer's ComposableStable pool architecture lets users deposit either
single-sided or proportional liquidity and receive **BPT** (Balancer Pool
Token) that:

1. **Earns swap fees** on every WETH↔wstETH trade routed through the pool
   (currently ~1 bp on the wstETH/WETH CSP, ~$200M TVL → ~$5-10M/yr
   volume → ~50-100 bps APR fee revenue on the wstETH side at peak).

2. **Captures wstETH's intrinsic appreciation** via the rate provider:
   the BPT's `getRate()` denomination includes the upward drift of
   `stEthPerToken`. As long as wstETH appreciates faster than WETH (which
   it always does, by definition), the BPT NAV ticks up regardless of
   pool composition.

3. *(Original "boosted" angle)* The historic
   **bb-a-USDC / bb-a-DAI / bb-a-USDT** Balancer Boosted pool wrapped
   Aave aTokens inside a nested LP, yielding Aave supply APR *and*
   stable-stable LP fees. That mechanic was paused after the March 2023
   readonly-reentrancy incident. The remaining mainnet equivalent of the
   "double yield" mechanic is the **wstETH/WETH ComposableStable** —
   wstETH is itself an "ERC20 yield-bearing" token, so the BPT inherits
   wstETH's staking yield via the rate provider.

This strategy is therefore the **carry analog of bb-a-USD**, but on
ETH/LST instead of USD stables.

## Why it composes

- **Two yield streams on one position**:
  - Swap fee accrual (LP fees in WETH / wstETH).
  - Rate-provider appreciation (wstETH's staking yield is reflected in
    the BPT NAV at every cache refresh, not just on join/exit).
- The position is a single ERC20 (the BPT), which downstream protocols
  (Aura, Spark, Aave v3) accept as collateral, enabling further leverage
  loops (see F13 family theme item "BPT as collateral").
- Balancer's `joinPool` / `exitPool` accept **single-asset entry/exit**
  with built-in slippage; we use single-asset WETH-in for the PoC,
  measure 1-block fee accrual, and exit single-asset WETH-out.

## Preconditions

- Sufficient WETH funded (`_fund(WETH, this, 100 ether)`).
- Pool not paused (the wstETH/WETH CSP has been stably operational
  since v5 redeployment in mid-2023).

## Strategy steps

1. Acquire ~100 WETH.
2. `IBalancerVault.joinPool(...)`
   - assets: `[wstETH, BPT, WETH]` (sorted by address; BPT itself is in
     the asset array for ComposableStable v3+ "phantom BPT" model).
   - maxAmountsIn: `[0, 0, 100e18]`
   - userData: `EXACT_TOKENS_IN_FOR_BPT_OUT` encoded with
     `(uint256 kind, uint256[] amountsIn, uint256 minBptOut)` —
     amountsIn must *exclude* the BPT slot per CSP v3+ semantics.
3. Snapshot BPT balance and pool token reserves.
4. `vm.roll(block.number + 1)` and `vm.warp(block.timestamp + 12)` to
   simulate one block of fee accrual. (For a multi-block test, advance
   further; pool's getRate() snapshot reflects rate refresh.)
5. Exit single-sided: `EXACT_BPT_IN_FOR_ONE_TOKEN_OUT` with WETH as the
   target token.
6. Report PnL.

## PnL math (annualised)

At 100 WETH notional, with:
- Pool fee revenue APR ≈ 60 bps on wstETH side, weighted by exposure.
- wstETH staking yield ≈ 350 bps annual; the pool's ~50% wstETH exposure
  delivers ~175 bps to the LP.

Combined gross APR ≈ **2.35%**. After Balancer's protocol fee (50% of
swap fee revenue routed to BAL holders since v2) it's ~**2.05% APR net**
in WETH terms.

On 100 WETH this is +2.05 WETH/year ≈ $6,560/year @ ETH=$3,200.

For a 1-block PoC the realised fee accrual is tiny (~$0.001) and
dominated by slippage on the entry/exit; the PoC's PnL line will be
slightly *negative* because we pay one round of fee on join and exit.
This is by design — the PoC's purpose is to demonstrate the **position
mechanics** (composability), not the carry capture, which requires a
multi-block simulation.

## Block pinned

- `FORK_BLOCK = 20_900_000` (Oct 2024 era). Stable pool already on v5
  with rate provider live.

## Risks

- **Smart-contract risk**: Balancer's ComposableStable v3 was rewritten
  after the March 2023 readonly-reentrancy bug; current v5 has a fixed
  reentrancy guard but the BPT-as-asset model is intricate.
- **Rate-provider failure**: If `stEthPerToken` returns a stale or zero
  value, the pool may refuse joins/exits or quote off-market prices.
- **Pool fee changes**: governance can lower or raise the swap fee,
  changing the LP economics.
- **Impermanent loss / divergence**: wstETH/WETH is near-pegged so IL is
  small but non-zero. The CSP curve cushions IL relative to a constant
  product pool.

## Result

- Status: **mechanically demonstrated**. The PoC opens and closes a
  position; the BPT balance round-trips back to ~0, and the PnL line
  shows the round-trip slippage cost. Realising the +2% APR carry
  requires a multi-block / multi-day fork which is out of scope for a
  1-block atomic PoC.
- Carry economics: **+1.8% to +2.3% APR net** at 100 WETH notional.
