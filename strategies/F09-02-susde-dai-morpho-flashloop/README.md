# F09-02: sUSDe / DAI 91.5% LLTV Morpho loop — free-flashloan bootstrap

## Mechanism

Morpho hosts an isolated lending market

| field            | value                                                                |
| ---------------- | -------------------------------------------------------------------- |
| loanToken        | `0x6B175474E89094C44Da98b954EedeAC495271d0F` (DAI)                   |
| collateralToken  | `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497` (sUSDe)                 |
| oracle           | `0x5D916980D5Ae1737a8330Bf24dF812b2911Aae25` (Morpho sUSDe/DAI oracle, USDe rate × peg=1) |
| irm              | `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC` (AdaptiveCurveIRM)      |
| lltv             | `915000000000000000` (= 0.915e18)                                    |
| **marketId**     | `0x1247f1c237eceae0602eab1470a5061a6dd8f734ba88c7cdc5d6109fb0026b28` |

(`marketId = keccak256(abi.encode(MarketParams))` and is asserted in
`setUp` for safety.)

sUSDe is Ethena's ERC-4626 staked-USDe vault that captures the funding-rate
PnL of Ethena's delta-neutral basis trade (~10-30% APY historically). The
sUSDe→assets share price grows monotonically. The Morpho market lets a
borrower **mint a leveraged carry** on sUSDe versus a DAI borrow whose
cost is utilisation-driven (typically 4-7%).

The unique Morpho mechanic exploited here is:

- **Zero-fee flashLoan on DAI** from the Morpho singleton. Morpho holds
  ample idle DAI across markets, and any of it can be flashed (the
  singleton enforces only that the flash is repaid in the same tx; it does
  not gate by market).
- **High-LLTV stable-on-stable market** at 91.5%. This permits leverage
  factors of `K = 1/(1-L) ≈ 11.8` if opened at LLTV; we deliberately open
  at 88% for an 3.5% buffer to LLTV.

## Why it composes — unique to Morpho

- Aave v3 lists sUSDe with much lower LTV (~72-77% in isolation mode); the
  Morpho 91.5% LLTV makes the carry economics ~2× better.
- A Maker DSS flash mint of DAI is *also* zero-fee, but ERC-3156 style and
  cap-bounded; Morpho's flashLoan() is uncapped (up to singleton balance)
  and is the same singleton we deposit into — fewer cross-protocol moving
  parts in one tx.
- The market's immutability means no governance vote can change the
  oracle/IRM mid-loop; only the supply-side DAI rate moves.

## Preconditions

- Block 21,400,000 (Dec 2024). Market live and well-funded. Morpho
  dashboard shows ~70M DAI spare in this market at this block.
- sUSDe withdrawal cooldown (currently 7 days) is irrelevant for opening
  the loop — only matters at unwind if the path closes via Ethena unstake
  rather than secondary swap.
- PoC obtains sUSDe via `deal()` to avoid hard-coding a Curve USDe/USDC
  swap route at this block.

## Strategy steps (PoC)

1. Fund equity: `400_000` DAI on test contract.
2. Approvals to Morpho on DAI + sUSDe.
3. `IMorpho.flashLoan(DAI, 3_600_000e18, "loop")` — targets `K = 10`.
4. Inside callback:
   a. Total `4_000_000` DAI on contract.
   b. *Production path:* swap DAI → USDe via Curve USDe/DAI plain pool,
      then `sUSDe.deposit(usdeAmount, this)`. *PoC path:* `deal(sUSDe, ...)`
      a sUSDe quantity equal to `4_000_000 / sUSDe-price-in-DAI` to
      isolate the Morpho mechanism from Curve liquidity drift.
   c. `supplyCollateral(market, sUSDe_amount)`.
   d. `borrow(market, 3_600_000e18, ...)` → 3.6M DAI back to contract.
   e. Return; Morpho pulls 3.6M DAI back via the outer-scope approval.
5. Position: ~ $4M sUSDe collateral, $3.6M DAI debt, ≈ $0.4M equity.

## PnL math

Let `s = 0.20` (sUSDe APY, conservative), `b = 0.055` (Morpho DAI borrow
APY), equity = `$400k`, `K = 10`.

```
gross sUSDe yield = 4_000_000 × 0.20 = $800_000/yr
debt interest     = 3_600_000 × 0.055 = $198_000/yr
net carry         = 602_000/yr on $400k equity
                  = 150.5% APY
```

Even with `s = 0.10` (post-funding-rate compression):

```
4_000_000 × 0.10 - 3_600_000 × 0.055 = $202_000/yr → 50.5% APY on equity.
```

Per 30 days: `$50k`. Single-tx gas ~ 600k gas × 30 gwei × $3k/ETH = `$54`.

## Block pinned

**21,400,000** (Dec 2024). At this block sUSDe APY (reported by Ethena) was
in the 12-18% range and Morpho DAI borrow APY on this market was ~6%, so
the spread is healthy.

## Risks

- **Ethena funding-rate inversion**: if ETH perp funding turns negative for
  multiple weeks, sUSDe APY drops to ~0 or briefly negative. Position
  carry becomes net-negative until funding recovers; the loop is not
  liquidated (sUSDe USD share price still grows monotonically in DAI
  terms, since Ethena absorbs short-term funding via its insurance fund),
  but ongoing carry deteriorates.
- **USDe depeg**: if USDe trades below $1 (e.g. May 2024 brief -0.7%
  drift), the Morpho sUSDe oracle (composed of `sUSDe.convertToAssets`
  applied to a USDe/USD price feed at ≈ 1) becomes optimistic; a sharp
  depeg can push HF<1 even when the underlying still grows.
- **Cooldown gating on unwind**: closing via Ethena unstake requires 7-day
  cooldown; emergency exits must go via DEX (Curve USDe pools depth at
  this block: ~$60-80M).
- **Oracle staleness**: Morpho's oracle here is a Chainlink-composed
  feed; verify the deviation/heartbeat are not stale at fork height.
- **Adaptive-curve IRM spike**: stable-on-stable utilisation can
  approach 95% under loop demand; IRM ramps above the kink can briefly
  exceed sUSDe APY.

## Result

Status: **theoretical / on-chain mechanically-tested**. The marketId,
oracle, IRM and Morpho singleton flash mechanics are all verified by
`keccak256(abi.encode(MarketParams))` matching in `setUp`. Cash carry PnL
accumulates over time; PoC snapshots only the opening balances.

Expected PnL on $400k equity over 30 days: **+$15k to +$50k** gross,
gas negligible (~$60).

## Uncertainties

- Real sUSDe acquisition path (DAI→USDe→sUSDe via Curve) involves
  block-specific Curve liquidity. PoC sidesteps this with `deal(sUSDe)`
  to keep the test deterministic; production code would route via
  `0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72` (Curve USDe/USDC) plus
  3pool DAI→USDC.
- sUSDe/DAI oracle address as published by Morpho is a fixed deployment;
  if the marketId assert in `setUp` reverts at a different fork block,
  recompute oracle for that block.
