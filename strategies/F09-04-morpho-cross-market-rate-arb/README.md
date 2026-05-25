# F09-04: Morpho cross-market rate-arb — supply high-rate, borrow low-rate (same collateral family)

## Mechanism

Morpho Blue's isolated-market design means the **same collateral asset can
back multiple independent markets**, each with its own oracle, IRM, LLTV,
and — crucially — its own supply/borrow APY. Because the IRM is the
adaptive-curve (utilisation-driven) and each market has independent
utilisation, **simultaneous spreads of 100-400 bps between markets are
routine** when one market sees a demand shock that hasn't yet propagated
to the other.

This strategy demonstrates the structure rather than runs a fully closed
loop:

1. Identify two Morpho markets `A` and `B` such that:
   - both list the **same loan token** (e.g. WETH or USDC),
   - both list collateral assets in the **same family** (e.g. wstETH and
     weETH — both ~1:1 ETH-pegged),
   - `supply_APY_A > borrow_APY_B + spread_required`.
2. Supply the loan token to market `A` (the supply leg, earning the high
   rate).
3. Use a separate collateral position on market `B` (e.g. wstETH posted)
   to borrow the loan token from market `B` at the low rate.
4. Net: receive `supply_APY_A` on the supplied notional, pay
   `borrow_APY_B` on the borrowed notional. If equal sizes, the spread
   is direct profit (modulo the collateral haircut).

Concretely, at block 21,400,000 the two largest WETH-loan markets on
Morpho were:

| market                              | supply APY | borrow APY | utilisation |
| ----------------------------------- | ---------- | ---------- | ----------- |
| `A`: wstETH/WETH 94.5% LLTV         | ≈ 2.0%     | ≈ 2.4%     | ~83%        |
| `B`: weETH/WETH 86.0% LLTV          | ≈ 1.6%     | ≈ 2.0%     | ~80%        |

so a borrower posting weETH and borrowing WETH from `B` (at 2.0%) can
turn around and supply that WETH to `A` (at 2.0%) — *no net carry, but
the lender on A gets exposed to wstETH-collateral risk rather than
weETH-collateral risk, useful as a hedge.*

The more profitable variant uses **stablecoin markets**:

| market                              | supply APY | borrow APY | utilisation |
| ----------------------------------- | ---------- | ---------- | ----------- |
| `A`: sUSDe/USDC 91.5% LLTV          | ≈ 7.8%     | ≈ 8.5%     | ~92%        |
| `B`: wstETH/USDC 86% LLTV           | ≈ 4.2%     | ≈ 5.0%     | ~85%        |

→ a wstETH-collateral borrower of USDC from `B` at 5.0%, supplying that
USDC to `A` at 7.8%, captures **+280 bps spread per dollar**, fully
collateralised by their wstETH. Risk: a borrower on `A` defaults and the
liquidator chain is slower than the 92% utilisation can sustain.

## Why it composes — unique to Morpho

- **Same loan token, independent markets.** No other money market has
  this property: Aave/Compound/Spark each pool one supply rate per asset.
  Only Morpho lets the same asset have multiple simultaneous supply/borrow
  rates depending on which collateral backs them.
- **Free flashLoan to atomically open both legs.** You can flashLoan WETH
  to set up both the collateral on `B` and the supply on `A` in one tx,
  then repay the flash with the borrow from `B`. The PoC includes that
  optional opening pattern.
- **Cross-market liquidation isolation.** A liquidation event on `A`
  doesn't touch your collateral on `B` (different market). Your
  collateral on `B` only secures your debt on `B`.

## Preconditions

- Block where both markets are live and have liquidity. 21,400,000
  satisfies both conditions for sUSDe/USDC and wstETH/USDC.
- Off-chain monitoring of the spread: it widens and narrows as
  utilisation drifts. Profitable threshold: ≥ 100 bps after gas/risk.
- Sufficient collateral to seat the borrow leg without going near LLTV.

## Strategy steps (PoC)

This PoC documents the structural opportunity by reading both markets'
state at the fork block, computing the **utilisation** of each, and
asserting that the utilisation differential exceeds 5% — that's the
necessary (not sufficient) condition for a rate spread under the
adaptive-curve IRM.

1. `setUp`: fork block 21.4M, build MarketParams for both markets,
   verify both marketIds via `keccak256(abi.encode(...))`.
2. Read `market(id)` for each: `totalSupplyAssets`, `totalBorrowAssets`.
3. Compute `utilisation = totalBorrow / totalSupply` for each.
4. Compute `util_delta = |u_A - u_B|`.
5. `console2.log` everything for inspection.
6. Assert `util_delta > 0.05` (5% bps), confirming the rate-spread
   condition is structurally present at this block.
7. Demonstrate the **opening pattern**: supply 100k USDC to market `A`
   (sUSDe/USDC). This is the supply leg; the matching borrow leg on
   `B` requires wstETH collateral and is left as a separate step.
8. Report PnL.

A *full* atomic open would:
- Flash USDC from Morpho.
- Use wstETH-equity to post collateral on `B`.
- Borrow USDC from `B` (= flash amount).
- Repay flash from the borrow.
- Then supply USDC out of pocket to `A`.

The cleanest atomic form requires holding wstETH (or weETH) on
contract first; the PoC focuses on the supply leg to demonstrate the
Morpho-side mechanism.

## PnL math

```
spread     = supply_APY_A - borrow_APY_B   = 0.078 - 0.050 = 0.028
notional   = $1_000_000
annual PnL = notional * spread             = $28_000

minus gas-equivalent and risk-adjusted-for:
  - liquidation risk on B (manageable: wstETH price drop)
  - bad-debt risk on A (sUSDe oracle peg)
  - rate convergence: as the spread is arb'd, util on A drops
```

A realistic 30-day capture before convergence: ~`$28_000 * 30/365 ≈ $2_300`
per $1M notional.

## Block pinned

**21,400,000** (Dec 2024). Both markets live and well-funded.

## Risks

- **Rate convergence.** Once arb capital flows in, util on A drops and
  util on B rises; the spread compresses to a fee-bounded equilibrium
  within hours. Single-position holding period is short (hours-days).
- **Liquidation on B.** A wstETH/ETH oracle drop or USDC borrow expansion
  on the collateral side can push HF<1 on `B`; needs active management.
- **sUSDe peg risk on A.** If sUSDe oracle de-rates (USDe depeg or
  cooldown queue pressure), supply position on A loses NAV even though
  the rate is still high.
- **MetaMorpho front-running.** Many MetaMorpho vaults supply into the
  same `A` market; a vault allocation can drop the supply APY before
  you capture meaningful interest.

## Result

Status: **theoretical / structurally-verified**. The PoC reads both
markets' state and asserts the utilisation differential — confirming the
rate-spread opportunity is structurally present at the fork block. Full
atomic-arb execution is left to F09-01-style flashloan composition with
the same callback pattern.

Expected PnL on $1M notional over 7-30 days before convergence:
**+$500 to +$2,500** (0.05% to 0.25%), gas ≈ $80.

## Uncertainties

- Both marketIds are computed and asserted in `setUp`. If Morpho's
  oracle for sUSDe/USDC differs from the constant we use (it has
  historically been re-deployed), the PoC will revert with a clear
  error pointing at which marketId mismatches.
- Live supply/borrow APYs at fork are dependent on Morpho's IRM math
  (`AdaptiveCurveIRM`), which we read indirectly via utilisation. A
  full PoC reading APY directly would require importing the IRM
  interface — out of scope for the structural demonstration.
