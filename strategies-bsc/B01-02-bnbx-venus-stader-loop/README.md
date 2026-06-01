# B01-02: Stader BNBx → Venus isolated pool → borrow BNB → BNBx re-stake loop

## Mechanism
Three composable BSC primitives stacked to lever Stader's BNB LST yield:

1. **Stader BNBx** — non-rebasing BNB LST whose exchange rate is exposed via
   `BNBx.getExchangeRate()` (1e18-scaled BNB-per-BNBx). The Stader
   `StakeManager` mints BNBx 1:1 (less a tiny fee) against the current
   exchange rate when BNB is deposited via `deposit{value: bnb}()`. BNBx
   rewards accrue silently in the exchange rate (~3.5–4 % APY).
2. **Venus isolated pool** — Venus V4 ships per-asset isolated pools with
   their own `Comptroller`. BNBx has a vBNBx market in one of these pools
   alongside a vBNB borrow asset. The isolated-pool surface is identical to
   the Core pool (Compound v2 fork) which is why the same `IVToken` /
   `IVenusComptroller` interfaces work.
3. **Recursive loop, but with the *isolated*-pool IRM** — isolated pools
   typically run a *more aggressive* IRM (higher kink utilization, lower
   below-kink slope) than Core, so the borrow APR for a given utilization
   level tends to be cheaper than the Core pool. This is the key alpha vs.
   B01-01: same loop, different IRM cost basis.

## Why it composes
- BNBx is non-rebasing, so the Venus accounting (which assumes share
  amounts are stable and the value accrues silently in the exchange rate)
  treats it cleanly as collateral. No share-rebasing surprises.
- The Stader mint path has no AMM hop: `deposit{value}()` mints BNBx at
  `getExchangeRate()` directly, so the re-stake leg of the loop has zero
  slippage and zero MEV exposure (atomic).
- Because the isolated-pool IRM is independent of Core, the strategy's
  borrow cost is decoupled from the much more crowded Core slisBNB /
  WBNB book. The same total leverage produces a higher net carry whenever
  the isolated-pool vBNB utilization is below the kink.

## Preconditions
- BSC block where the Venus isolated pool listing BNBx as collateral is
  live and has non-zero supply liquidity for vBNB borrowing.
- `BNBx.getExchangeRate()` returns a sane value (> 1e18) — i.e. BNBx is not
  paused and is accruing.
- Stader `StakeManager.deposit{value}()` is open (not throttled by the
  per-block stake cap). At low principal sizes (≤ 1k BNB) this is rarely
  an issue.

## Strategy steps
1. Start with 100 BNB principal in native form.
2. Mint BNBx via `StaderStakeManager.deposit{value: bnb}()`. Receive
   `bnb * 1e18 / getExchangeRate()` BNBx shares.
3. `Comptroller.enterMarkets([vBNBx, vBNB])` on the isolated-pool comptroller.
4. Iteration loop (N=4):
   - `vBNBx.mint(BNBx_balance)` — supply BNBx collateral.
   - `vBNB.borrow(borrowAmt)` where `borrowAmt = liquidity * SAFETY_BPS`.
   - Re-stake the borrowed BNB via `StaderStakeManager.deposit{value}()`.
5. After the last iteration, supply the residual BNBx.
6. Hold 30 days; force interest accrual; report PnL relative to the BNB
   value of (BNBx collateral − vBNB debt).

## PnL math
Per 100 BNB principal, 30-day horizon:
- BNBx stake APY: ~3.8 %
- Isolated-pool vBNB borrow APR: ~1.9 % (vs ~2.2 % on Core)
- BNBx collateral factor: ~0.65 (more conservative than slisBNB)
- Effective leverage L = 1 + 0.65 + 0.42 + 0.27 + 0.18 ≈ 2.52×
- Net APY at L=2.52: (2.52 × 3.8 − 1.52 × 1.9) = 9.576 − 2.888 = **+6.69 %**
- 30-day yield: 6.69 × 30/365 ≈ **+0.550 % on principal ≈ +0.55 BNB**

The borrow-side savings (0.3 ppt cheaper than Core) are the main
discriminator versus B01-01.

## Block pinned
**40_500_000** (mid-2024) — Venus V4 isolated pool with BNBx listed; Stader
StakeManager is operational. Refine once `BSC.vBNBx` is verified.

## Addresses used
- `0x1bdd3Cf7F79cfB8EdbB955f20ad99211044F6aE4` — Stader BNBx (`BSC.BNBx`).
- `LOCAL_STADER_STAKE_MANAGER` — Stader StakeManager (not in `BSC.sol`).
  Inline placeholder; verify against on-chain at pinned block once BSC RPC
  is available. Stader's docs point at
  `0x7276241a669489E4BBB76f63d2A43Bfe63080F2F` (V2 manager); this strategy
  uses that address.
- `LOCAL_VBNBX_COMPTROLLER` — isolated-pool Comptroller for the BNBx
  market. Placeholder set to the Stableswap pool comptroller; refine.
- `LOCAL_VBNBX` — vBNBx market token. Placeholder set to one of the known
  isolated-pool listings; refine post-RPC.
- `0xA07c5b74C9B40447a954e1466938b865b6BBea36` — vBNB (Core, used as the
  borrow asset proxy until isolated-pool vBNB is verified).

## Risks
- **Isolated-pool depth**: isolated pools start with shallower vBNB
  liquidity than Core. A 100-BNB position may push utilization > 80 % and
  blow the IRM kink, flipping the carry negative. Cap position size to
  ≤ 5 % of vBNB supply at entry.
- **BNBx redemption queue**: Stader has a similar 7–10 day unbond as Lista.
  Exit at scale requires PCS v3 BNBx/WBNB pool (low depth) or partial
  unwind via `requestWithdraw`.
- **Isolated-pool governance**: the isolated comptroller may pause borrows
  independently of Core. Monitor per-pool governance feed.
- **BNBx slashing**: Stader's validator set is small. A slashing event
  drops `getExchangeRate()`, marking down the collateral.

## Result
Status: **theoretical** (no BSC RPC yet). Expected PnL: **+0.4–0.7 BNB per
100 BNB over 30 days**. The exact figure depends heavily on isolated-pool
vBNB borrow APR at the pinned block; the strategy is unprofitable if
borrow > 3.8 % (the BNBx native APY ceiling).
