# B01-03: ankrBNB → Lista Lending → borrow BNB → Ankr re-stake loop

## Mechanism
Three composable BSC primitives stacked into a leveraged ankrBNB position
that *deliberately avoids Venus* to exploit a different lending venue's IRM:

1. **Ankr ankrBNB** — non-rebasing BNB LST. The ratio `ratio()` returns the
   BNB-per-ankrBNB exchange rate (1e18-scaled), with convenience wrappers
   `sharesToBonds` / `bondsToShares`. The Ankr `BinancePool` contract mints
   ankrBNB 1:1 against the current ratio when BNB is deposited via a
   `stakeAndClaimCerts{value: bnb}()` flow.
2. **Lista Lending** — the Aave-style isolated lending market run by Lista
   DAO. It lists ankrBNB (and slisBNB, BNBx) as collateral with a published
   LTV and supports borrowing native BNB. Surface: `supply`, `borrow`,
   `withdraw`, `repay` against `IListaLending`.
3. **Recursive ankrBNB loop on Lista Lending** — Lista's IRM is independent
   of Venus' Comptroller, so even when Venus vBNB borrow APR spikes (e.g.
   during a Core-pool credit shock) Lista's BNB borrow rate can remain flat.
   This is a *venue-diversification* play: the loop's economics are tied
   to Lista's BNB pool, not Venus'.

## Why it composes
- ankrBNB on Lista Lending is a *different* collateral configuration than
  Venus: Lista typically gives ankrBNB a tighter LTV (~0.60) because of
  ankrBNB's thinner spot liquidity, but in exchange it has a cleaner BNB
  borrow IRM that does not get crowded by slisBNB recursive farmers.
- The Ankr mint path (`stakeAndClaimCerts`) is atomic and slippage-free,
  same as Lista's and Stader's. The composition `BNB → ankrBNB → Lista
  collateral → BNB borrow → ankrBNB` is fully on-chain, no AMM hops.
- Result: the BNB borrow APR floor is decoupled from Venus, which is the
  whole point of having a multi-venue stack within the family.

## Preconditions
- BSC block where Lista Lending is live with ankrBNB collateral and a BNB
  borrow market.
- Ankr `BinancePool` not paused; ratio sane (> 1e18).
- Lista Lending has sufficient BNB supply for the planned loop draw.

## Strategy steps
1. Start with 100 BNB principal in native form.
2. Mint ankrBNB via `Ankr.stakeAndClaimCerts{value: bnb}()`. Receive
   `bnb * 1e18 / ratio()` ankrBNB shares.
3. `IListaLending.supply(ankrBNB, balance, address(this))` to deposit
   collateral.
4. Iteration loop (N=4):
   - Read `getUserAccountData` → `availableBorrowsBase`.
   - `IListaLending.borrow(WBNB, borrowAmt * SAFETY_BPS / 10_000,
     address(this))`.
   - Unwrap WBNB → BNB.
   - Re-stake via `Ankr.stakeAndClaimCerts{value: bnb}()`.
   - `supply` the new ankrBNB.
5. Hold 30 days; force interest accrual on the debt; report PnL relative
   to the BNB value of (ankrBNB collateral − BNB debt).

## PnL math
Per 100 BNB principal, 30-day horizon:
- ankrBNB stake APY: ~3.5 % (Ankr's APY is generally a touch lower than
  Lista's, since the validator set is smaller and reward path different).
- Lista Lending BNB borrow APR: ~1.7 % (favorable; thinner book, lower
  utilization)
- ankrBNB LTV on Lista: ~0.60
- Effective leverage L = 1 + 0.60 + 0.36 + 0.216 + 0.130 ≈ 2.30×
- Net APY at L=2.30: (2.30 × 3.5 − 1.30 × 1.7) = 8.05 − 2.21 = **+5.84 %**
- 30-day yield: 5.84 × 30/365 ≈ **+0.48 % on principal ≈ +0.48 BNB**

## Block pinned
**41_000_000** (mid-2024) — Lista Lending V1 live with ankrBNB collateral.
The Lista Lending address (`BSC.LISTA_LENDING`) is currently a TODO-verify
placeholder; the PoC inlines a `LOCAL_LISTA_LENDING` constant and the user
should refresh once the canonical address is confirmed.

## Addresses used
- `0x52F24a5e03aee338Da5fd9Df68D2b6FAe1178827` — ankrBNB (`BSC.ankrBNB`,
  also used for aBNBc). // BSC.sol marks this `TODO verify`; treat as
  authoritative pending RPC check.
- `LOCAL_ANKR_BINANCE_POOL` — Ankr's `BinancePool` (mint path). Inline
  placeholder `0x9e347Af362059bf2E55839002c699F7A5BaFE86E`; verify on-chain.
- `LOCAL_LISTA_LENDING` — Lista Lending pool. Inline placeholder taken
  from `BSC.LISTA_LENDING`; refresh once the canonical address is verified.

## Risks
- **ankrBNB ratio stall**: Ankr's reward distribution is centralized; a
  delay in ratio update means the collateral leg under-reports yield.
- **Lista Lending shallowness**: if the BNB supply on Lista Lending is
  thin (e.g. < 5k BNB), the borrow can push utilization → kink and the IRM
  flips negative-carry. Bound position to ≤ 5 % of BNB supply.
- **Multi-venue oracle skew**: Lista's ankrBNB oracle and Ankr's `ratio()`
  may diverge during validator-event windows; liquidation risk rises until
  Lista updates its oracle.
- **Unwind asymmetry**: ankrBNB redemption queue is ~7 days. PCS v3
  ankrBNB/WBNB pool has low depth; for fast exit slippage can exceed
  0.5 %.

## Result
Status: **theoretical** (no BSC RPC yet, and Lista Lending address is
TODO-verify). Expected PnL: **+0.3–0.6 BNB per 100 BNB over 30 days**, with
upside if Lista's BNB borrow APR holds well below Venus.
