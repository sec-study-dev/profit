# B06-02: Venus Core Pool VAI mint + Pancake StableSwap VAI/USDT carry

## Family
B06 — Venus V4 isolated pool / native-stable mechanism arbitrage. This
strategy is the "VAI side" of the family: instead of an inter-Comptroller
rate gap, it uses **Venus' Core Pool VAIController** to mint VAI against
USDC collateral, then deploys the freshly minted VAI into a Pancake
StableSwap pool to harvest swap fees + emissions while paying the (often
zero or near-zero) VAI stability fee back to Venus.

## Mechanism — three composable BSC primitives stacked

1. **Venus Core Pool collateral.** Standard `enterMarkets([vUSDC])` +
   `vUSDC.mint(usdc)` opens a USDC-collateralised borrow capacity (CF ≈ 0.80
   for USDC on Core).
2. **Venus VAIController `mintVAI`.** Sister contract to the Core
   Comptroller, governance-owned, lets a user with positive account liquidity
   mint VAI 1:1 against their *remaining* USD-denominated liquidity (no
   borrow on a vToken, no swap). VAI is BSC's overcollateralised native
   stable, address `0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7`. The
   stability fee (VAI mint rate) is governance-set and has historically
   floated between 0 % and 2 % APR. When fee ≈ 0 the mint is essentially
   free capital.
3. **Pancake StableSwap VAI/USDT/USDC pool.** Curve-fork on BSC. VAI is
   one of the three coins in the canonical "VAI 3pool". LPing here pays
   swap fees on the natural VAI ↔ stable arb flow plus CAKE emissions
   when the gauge has weight.

The strategy stacks the three: collateralise USDC, mint VAI against the
free capacity, deposit VAI into the StableSwap pool, hold for 60 days, and
collect: (swap fees + CAKE emissions − VAI stability fee − vUSDC
opportunity cost).

## Why it composes (3 distinct Venus / Pancake mechanisms)
- **Mechanism A — VAI free-mint.** Unlike borrowing USDT from `vUSDT`, VAI
  mint goes directly through VAIController and does *not* draw on a vToken's
  reserve. So vUSDC supply rate keeps accruing on the *full* 1M USDC even
  while we mint 800k VAI against it. **The collateral keeps earning supply
  APY while the mint funds a second yield leg** — the two yields stack on
  the same dollars.
- **Mechanism B — VAI stability fee << expected StableSwap APY.** Empirically
  the VAI mint fee has been 0–2 % while the VAI/3stable StableSwap pool
  has earned 4–8 % from CAKE emissions alone, plus ~1 % from swap fees.
- **Mechanism C — VAI peg defended by Venus' own redemption.** When VAI
  trades below $1 on the StableSwap, arbitrageurs buy and `repayVAI` to
  retire debt at par, which pulls the StableSwap quote back. This bounds
  the LP's depeg loss to ~50 bp historically.

This is the *original native-stable carry* pattern, ported from Maker's
DAI-PSM era and from Lista's lisUSD `interaction` flow: mint at near-zero
cost, deploy at a yielding venue, profit from the spread.

## Preconditions
- BSC block where the Pancake StableSwap VAI/USDT/USDC pool is active and
  the gauge has nonzero CAKE emissions. The pool is
  `LOCAL_PCS_VAI_3POOL` (inlined). **TODO verify** address against the
  canonical PCS StableSwap factory at the pinned block.
- Venus VAIController is not paused (`mintVAIRate` < threshold).
- Account is fresh (no existing Venus debt) so the full `getAccountLiquidity`
  is available for VAI minting.

## Strategy steps (in `testStrategy_B06_02`)
1. Fund `address(this)` with 1,000,000 USDC.
2. `enterMarkets([vUSDC])` on Core Comptroller; `vUSDC.mint(1_000_000e18)`.
3. Read `getAccountLiquidity` (~ `1M × 0.80 = 800k` USD).
4. Call `VAIController.mintVAI(800_000e18 * SAFETY_BPS / 10_000)` —
   safety haircut of 95 % so a small Venus accounting rounding doesn't
   trip the liquidity check.
5. Approve the StableSwap pool for VAI and add liquidity single-sided
   (or via the router's `add_liquidity([dx_vai, 0, 0], 0)`).
6. Hold 60 days. During this window:
   - vUSDC supply interest accrues on full 1M USDC.
   - VAI stability fee accrues on minted VAI (paid in VAI at burn).
   - LP earns swap fees + CAKE emissions.
7. Unwind: remove StableSwap LP (single-sided back to VAI), `repayVAI`,
   redeem vUSDC.
8. `_endPnL` reports net of: (LP yield + vUSDC supply yield − VAI stability
   fee − gas − any peg slippage on unwind).

## PnL math (1M USDC principal, 60-day hold)

| Leg                              | Annualised | 60-day on 1M |
| -------------------------------- | ---------- | ------------ |
| vUSDC supply (1M notional)       | +3.0 %     | +$4,932      |
| StableSwap fees (800k notional)  | +1.0 %     | +$1,315      |
| CAKE emissions (800k notional)   | +5.0 %     | +$6,575      |
| VAI stability fee (800k)         | −1.0 %     | −$1,315      |
| Peg slippage at unwind (10 bp)   | one-shot   | −$800        |
| Gas                              | one-shot   | −$2          |
| **Net**                          |            | **+$10,705** |

Effective APY on the *USDC* base: **6.5 %**, which is competitive with the
best yieldcoin curves at the cost of moderate complexity.

## Block pinned
**42_500_000** — pinned together with B06-01 so both strategies share a
fork cache. Re-pin once BSC_RPC_URL is available.

## Addresses used (inlined VAIController + StableSwap pool)
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Core Comptroller (`BSC.VENUS_COMPTROLLER`).
- `0xecA88125a5ADbe82614ffC12D0DB554E2e2867C8` — vUSDC (`BSC.vUSDC`).
- `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` — USDC (`BSC.USDC`).
- `0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7` — VAI (`BSC.VAI`).
- `LOCAL_VAI_CONTROLLER = 0x004065D34C6b18cE4370ced6fE0F35bcd06b8B96` —
  Venus VAIController (proxy). **TODO verify** at pinned block.
- `LOCAL_PCS_VAI_3POOL = 0x5B5bB9765eff8d26c6bba4F5d52D86D3d5b6C1FA` —
  PCS StableSwap VAI/USDT/USDC pool. **TODO verify** — also resolvable via
  PCS StableSwap InfoRouter at the pinned block. Pool index in the
  canonical pool list (VAI is coin index 0).

## Risks
- **VAI sustained depeg.** If VAI trades persistently below $0.99, the
  unwind costs widen and the carry can flip negative. Mitigation: 60-day
  hold but PoC includes an early-exit branch (`block.timestamp drift > T`
  → unwind sooner).
- **VAI stability fee bump.** Venus governance can spike `mintVAIRate`
  (already done once during a 2022 emergency). Mitigation: PoC reads
  rate before and after the warp; in real ops, position is monitored
  with a daily script.
- **Liquidation on USDC collateral.** Stables don't move much, but a USDC
  depeg + a Venus oracle update could trigger shortfall. Mitigation: 95 %
  safety haircut on VAI mint.
- **StableSwap pool address may be stale.** The PCS StableSwap factory
  has redeployed once; PoC notes the TODO and the PoC swaps in a
  resolver-based lookup if BSC_RPC_URL is available.

## Result
Status: **theoretical, offline**. Expected net: **+$10k–$12k per 1M USDC
per 60 days** at the pinned block, with the bulk coming from CAKE
emissions on the LP leg.
