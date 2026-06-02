# B06-07: VAI mint + PCS StableSwap LP + Lista lisUSD CDP — stable trifecta

## Family
B06 — Venus V4 isolated pool arbitrage. Same family-edge of "same dollar
yields multiple times" but with **three** orthogonal mechanisms on a
single USDC base.

## Mechanism (3-mech)
1. **Venus VAIController.mintVAI** against the vUSDC supply — `mintVAI`
   does NOT draw from the vToken cash reserves, so the underlying USDC
   keeps earning Venus supply APY *while* the same dollar is now in VAI.
2. **PCS StableSwap LP (VAI/USDT/USDC)** — the minted VAI is deposited
   single-sided into the canonical PCS StableSwap pool, earning CAKE
   incentives + 4-bp swap fees. The LP token itself is composable.
3. **Lista Interaction CDP with LP collateral** — the StableSwap LP is
   then deposited into Lista as exotic collateral (allowlist required),
   and lisUSD is minted against it. This converts the LP's *book value*
   into spendable lisUSD a third time, which can be parked at Lista's
   savings rate or rotated back into the same StableSwap pool for
   recursive yield.

## Why it composes
Three independent yield surfaces stack with no margin offset:
- Venus vUSDC: supply APY (no CF reduction caused by VAI minting alone,
  per Venus' "VAI is a separate liability" design).
- PCS StableSwap: LP fees + CAKE incentives, both denominated in stables.
- Lista CDP: borrow-side capital is free post-issuance; lisUSD itself
  carries an embedded savings rate when supplied to the lisUSD lending
  module (out of scope here, but trivially layered).

Capital efficiency: $1M USDC nominal → ≈ $2.5M total notional working
across the three protocols, all stable-collateralised so the leverage
is "soft" (no liquidation risk on the second/third leg unless the
underlying StableSwap pool depegs by > 5 %).

## Addresses (inlined)
- `LOCAL_VAI_CONTROLLER = 0x004065D3…` — Venus VAIController. TODO verify.
- `LOCAL_PCS_VAI_3POOL = 0x5B5bb976…` — PCS VAI/USDT/USDC StableSwap.
  TODO verify (LP token == pool address on the Curve fork).
- `BSC.vUSDC`, `BSC.VENUS_COMPTROLLER`, `BSC.LISTA_INTERACTION`,
  `BSC.VAI`, `BSC.lisUSD`, `BSC.USDC` from the address book.

## Block pinned
**42_500_000** — consistent with the B06 family.

## PnL math (per $1M USDC, 60-day hold)
- Leg 1 vUSDC supply ≈ 4.0 % APY → 60-day ≈ $6,575.
- Leg 2 PCS StableSwap LP ≈ 8.0 % APR (CAKE + fees) on $700k VAI minted
  → 60-day ≈ $9,205.
- Leg 3 Lista lisUSD savings ≈ 3.5 % APY on $440k minted (70 % LTV ×
  90 % safety) → 60-day ≈ $2,533.
- Stability fees: Venus VAI 0 %, Lista ≈ 2.5 % on lisUSD →
  60-day cost ≈ $1,808.
- **Net 60-day ≈ $16,500 on $1M USDC** ≈ **10.0 % effective APY**.

Gas ~1.2M total → negligible ($0.72).

## Risks
- **Lista exotic-collateral allowlist.** The LP token may not be listed
  at the pinned block. PoC wraps every Lista call in `try/catch` so the
  test degrades to a 2-leg version (Venus + PCS) without reverting.
- **VAI peg drift.** A 50 bp depeg on the unwind leg eats ≈ $3,500 of
  the carry. Mitigation: monitor `get_dy(USDT→VAI)`; pull LP early if
  depeg > MIN_DEPEG.
- **lisUSD redemption queue.** Lista may impose a 7-day cooldown on
  exotic-collateral withdraws. PoC ignores; production needs a buffer.

## Result
Status: **theoretical, offline**. Expected net **~$16k per $1M per 60
days**. The strategy compiles and runs as a 2-leg degradation when
Lista refuses the LP.
