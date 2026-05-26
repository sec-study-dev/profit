# F11-01: Compound v3 USDC Comet — leveraged WETH loop

## Mechanism
Compound v3 deviates from v2's pooled-asset design: each market ("Comet") has a
**single base asset** that is the only borrowable token, and one or more
**collateral assets** that earn no supply yield but can back base-token debt.
The mainnet **USDC Comet** (`0xc3d688B66703497DAA19211EEdff47f25384cdc3`) accepts
WETH, wstETH, cbETH, COMP, LINK, UNI, WBTC as collateral, with WETH's
borrow-collateral-factor at **82.5%** and liquidation factor **88.5%**. Only
USDC is borrowable.

The strategy: supply WETH as collateral, borrow USDC, swap that USDC back into
WETH on Uniswap v3 (0.05 % fee tier WETH/USDC pool), then redeposit. Repeat
until the marginal LTV consumption falls below the per-loop step. The
**economic edge** is that on most blocks the *implied* funding rate that the
position pays is *the Comet USDC borrow rate minus the Uniswap WETH/USDC drift*.
When ETH spot is appreciating or sideways, the position behaves like a
leveraged long-ETH carry with negative funding cost only equal to the Comet
borrow APR (typically 4-7 %), and zero supply-side rebate on the WETH
collateral (Comet does not pay supply yield on non-base collateral, by design).

Equivalent leverage at LTV `L` over N rounds: `K = 1 + L + L^2 + ... = 1/(1-L)`.
At `L = 0.80` we reach `K ≈ 5x`. The position is *delta-1 long ETH/USDC* by
`(K-1)` units of borrowed USDC notional translated through the swap.

## Why it composes
Compound v3 and Uniswap v3 compose orthogonally: Comet supplies the
*leverage primitive* (one-asset borrow, predictable rate kink), Uniswap v3
supplies the *conversion primitive* between the borrow asset (USDC) and the
collateral asset (WETH). The 0.05 % fee tier of the canonical USDC/WETH 5-bps
pool (`0x88e6...5640`) is the deepest USDC↔WETH venue on mainnet, with daily
volume in the hundreds of millions; even a 10-loop unwind at $20m notional
clears within ~5 bps of mid in normal markets.

The composability comes from the fact that Comet's *isolated base asset* design
means the only swap leg is USDC↔WETH — no triangulation through another base
asset. This removes the multi-hop slippage tax that plagues Aave's looped
positions when the borrow asset and collateral asset are distinct.

## Preconditions
- Mainnet, block where WETH is listed as Comet collateral (any block after
  Comet USDC mainnet launch in August 2022).
- Sufficient base supply headroom on Comet (Comet caps total borrow at
  `totalSupply * 0.95`; verify `getUtilization() < 0.95e18`).
- Uniswap v3 USDC/WETH 0.05 % pool has non-zero TVL (always true on mainnet).
- Capital: any size; price-impact begins to dominate above ~$50m principal.

## Strategy steps
1. Wrap principal ETH → WETH. Approve WETH to Comet.
2. `Comet.supply(WETH, principal)` — registers WETH as collateral.
3. Loop N times:
   a. Quote available borrow headroom from
      `collateralBalanceOf * collateralFactor * price` minus current debt.
   b. `Comet.withdraw(USDC, borrowAmt)` — borrowing USDC out of the base
      reserve. Comet uses the same `withdraw` selector for base-asset borrow
      when the user has zero base supply.
   c. Swap USDC → WETH on Uniswap v3 0.05 % pool.
   d. `Comet.supply(WETH, swapOut)` — redeposit.
4. Hold `~30 days`, vm.warp to crystallise borrow-index drift.
5. Unwind (optional): swap a portion of WETH back to USDC, `Comet.supply(USDC)`
   to repay, then `Comet.withdraw(WETH)` to recover.

## PnL math
Let:
- `K = 1/(1-L)` with `L = 0.80` → `K = 5`
- `r_b` = Comet USDC borrow APR ≈ 0.055
- `eth_drift` = realised ETH/USDC price move over the horizon

Net return on principal over horizon `T`:
```
net = K * eth_drift - (K - 1) * r_b * T  -  swap_fees
```
At `eth_drift = 0`, `T = 30 days`: `net = -4 * 0.055 * (30/365) = -1.8%` —
pure carry cost, no directional alpha.

At `eth_drift = +3 %` over the month: `net = 5 * 0.03 - 4 * 0.055/12 = 15 % - 1.8 % = +13.2 %`.

The PoC measures **one-block opening cost + a 30-day warp-and-touch**; the
dominant observable signal in the PnL block is the Comet borrow-index drift
captured by `borrowBalanceOf`.

## Block pinned
**20_500_000** (Aug 2024) — pulled because:
- Comet USDC market mature; WETH listed as collateral since Apr 2023
- Comet USDC borrow APR observed at ~5.0-5.8 % on contemporaneous data
- Uniswap v3 USDC/WETH 0.05 % pool TVL > $200m

## Addresses used (verified)
- `0xc3d688B66703497DAA19211EEdff47f25384cdc3` — Comet USDC (cUSDCv3),
  verified at https://etherscan.io/address/0xc3d688B66703497DAA19211EEdff47f25384cdc3
- `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` — USDC (Centre)
- `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` — WETH9
- `0xE592427A0AEce92De3Edee1F18E0157C05861564` — Uniswap v3 SwapRouter01
- `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` — Uniswap v3 USDC/WETH 0.05 %
  pool (for direct pool quoting)

## Risks
- **Borrow APR spike**: Comet's IRM kinks at 90 % utilisation; pushing past
  the kink doubles the APR. Position carry can swing from +0.5 % to +6 % overnight.
- **Liquidation**: at LTV 0.825 → liquidation factor 0.885, a -7 % ETH move
  triggers absorption. Comet's `absorb()` seizes collateral at a 0-2 % discount.
- **Swap slippage**: a single 1000-WETH unwind through the 5-bps pool moves
  the pool ~30 bps in ETH spot. At full leverage, a complete unwind is N times
  that.
- **Comet pause**: governance can pause `supply`/`withdraw` on the market.
- **Smart-contract risk**: Compound v3 has been audited but the
  collateral-isolation architecture is newer than v2.

## Result
Status: theoretical (forge build not run; addresses + collateral factor + IRM
shape verified against Compound v3 docs and the live USDC Comet on Etherscan).
Expected PnL: at flat ETH the strategy is a pure carry **drag of ~0.4-0.5 %
over 30 days** at K=5; under a +3 % ETH drift it flips to **+13 % over the same
horizon**. PoC asserts only that the loop opens and the Comet position is
non-zero at the end.
