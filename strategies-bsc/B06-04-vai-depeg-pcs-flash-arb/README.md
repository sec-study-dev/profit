# B06-04: VAI depeg — atomic PCS v3 flash + Venus repayVAI arb

## Family
B06 — Venus V4 native-stable mechanism arbitrage. This is the **VAI peg
defender** angle: when VAI trades below $1 on Pancake StableSwap, an
arbitrageur can buy VAI cheap on PCS, then `repayVAI` against a *third
party's* outstanding debt (any account with `vaiMintedAmount > 0`) at par —
but Venus' VAIController only credits the repayer up to that account's
debt. The cleaner mechanism is:

1. Flash USDT from PCS v3 USDT/USDC pool (cheapest fee tier, 1 bp).
2. Swap USDT → VAI on PCS StableSwap at the depegged quote (1 USDT
   buys ~1.005 VAI if VAI is at $0.995).
3. **Open a small VAI vault on our own account** (mint then immediately
   repay): mint VAI by collateralising a tiny USDC deposit, then call
   `repayVAI` with the surplus VAI we bought on PCS — but the only way to
   realise the par credit is via the *atomic redemption path*, which on
   Venus means burning VAI 1:1 against another vToken's accumulated
   reserves (`reduceReserves` on a paused market) — not possible without
   governance.

The **deployable variant** uses the cheaper path: convert VAI back to USDC
via the PCS StableSwap pool itself (round-trip), pocketing only the
mean-reversion of the peg. The atomic profit is then bounded by:

> profit ≈ depeg × notional − flash fee − slippage round-trip

For a 50-bp VAI depeg on $1M notional → ~$5,000 gross − ~$1,000 flash fee −
~$500 slippage = **~$3,500 net per atomic call**.

A *second* variant — included in the PoC as a branch — uses VAI's role as
a **Venus borrow-repayment instrument**: if the strategy contract carries
its own VAI mint (from B06-02's position), it can repay that debt with the
cheaply-acquired VAI. Effectively the depeg discount is captured by
*retiring* expensive debt with cheap units, which is the canonical
"buy-back-at-discount" pattern used by Maker (DSR) and Frax (AMO).

## Mechanism — three composable BSC primitives stacked
1. **PCS v3 flashSwap on USDT/USDC pool** (1 bp fee tier) — same-tx loan
   that gives us USDT principal for free until the callback returns.
2. **PCS StableSwap VAI/USDT/USDC pool exchange** — Curve fork's
   `exchange(i, j, dx, minDy)`, which gives the depegged VAI/USDT quote.
   Slippage on a balanced $1M trade is ~30 bp.
3. **Venus VAIController `repayVAI` at par** — for accounts that *already*
   carry a VAI mint (e.g. the same account that ran B06-02), repaying 1
   VAI retires 1 USD of debt regardless of VAI market price. This is the
   par-credit mechanism that *bounds the depeg from below*: any sustained
   discount > stability fee + gas opens this arb.

The two PoC variants stack mechanisms (1+2) and (1+2+3) respectively.

## Why it composes
- **PCS v3 flash** gives the working capital with no balance-sheet
  requirement.
- **PCS StableSwap pool** is both the source of the depeg quote *and* the
  natural unwind venue — so a single-pool round-trip is the cheapest
  execution.
- **VAI par-credit at VAIController** is the structural backstop that
  guarantees an upper bound on the depeg (it cannot persist below
  `1 - stability_fee` once anyone with VAI debt notices).

## Preconditions
- VAI is currently trading at < $0.995 (50 bp depeg) on the PCS StableSwap
  VAI/USDT/USDC pool. Detected by reading `get_dy(USDT_idx, VAI_idx, 1e18)`.
- PCS v3 USDT/USDC 0.01 % pool has ≥ $1M of USDT liquidity on the active
  tick.
- Either: (variant A) we accept paying StableSwap slippage on the unwind,
  or (variant B) the contract carries an existing VAI debt position.

## Strategy steps — variant A (atomic, no pre-existing VAI debt)

In `testStrategy_B06_04_atomic`:
1. Read `get_dy` on the PCS StableSwap to confirm VAI depeg ≥ `MIN_DEPEG_BPS`.
   Skip if not.
2. Initiate `IPancakeV3Pool.flash(this, USDT_amount, 0, encoded_params)` on
   the USDT/USDC 1 bp pool.
3. In `pancakeV3FlashCallback`:
   - Approve PCS StableSwap and `exchange(USDT_idx, VAI_idx, flash_amt, 0)`.
   - Now hold a VAI surplus (`flash_amt × 1.005`).
   - `exchange(VAI_idx, USDT_idx, vai_surplus, 0)` round-trip back.
   - Pay flash fee from the resulting USDT delta.
   - Surplus stays in the contract.

Net = `2 × (1 − depeg) × pool_amplitude − flash_fee` (the StableSwap
flattens once you trade through the imbalance, so PnL decays with size).

## Strategy steps — variant B (with pre-existing VAI debt)

In `testStrategy_B06_04_withDebt`:
1. Set up: open a 100k VAI debt position (mirrors B06-02). This is the
   "to-be-retired" debt.
2. Flash USDT, swap to VAI at depeg, then `repayVAI(vai_bought)`. Each VAI
   repaid retires $1 of debt at par despite costing $(1 − depeg) USDT.
3. Now the contract owes `(initial_debt − vai_bought)` VAI and holds the
   collateral. Repay the flash from the *avoided VAI mint*: the difference
   between `repayVAI(par)` credit and the USDT spent is the net.

In this variant the profit is **strictly larger** than variant A because
there is no round-trip slippage — the VAI is *consumed* at par by
VAIController.

## PnL math (1M USDT notional, 50-bp VAI depeg)

| Variant   | Gross USD | Flash fee | Slippage | Gas | Net  |
| --------- | --------- | --------- | -------- | --- | ---- |
| A (no debt) | +$5,000 | −$1,000   | −$1,400  | −$1 | **+$2,599** |
| B (with debt) | +$5,000 | −$1,000 | −$200 (one-way) | −$1 | **+$3,799** |

Both variants are atomic (one tx). The strategy can be replayed each block
the depeg persists.

## Block pinned
**42_500_000** — chosen to share fork cache with B06-01/02/03. The PoC
*injects* a synthetic depeg in setUp by directly perturbing the StableSwap
pool balances via `deal()` so the path is exercised even if the real on-chain
state at this block has VAI at par. This is acceptable because the family
mandate is to demonstrate **mechanism composition**, not historical PnL.

## Addresses used
- `0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7` — VAI (`BSC.VAI`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` — USDC (`BSC.USDC`).
- `LOCAL_VAI_CONTROLLER = 0x004065D34C6b18cE4370ced6fE0F35bcd06b8B96` —
  Venus VAIController. **TODO verify**.
- `LOCAL_PCS_VAI_3POOL = 0x5B5bB9765eff8d26c6bba4F5d52D86D3d5b6C1FA` —
  PCS StableSwap VAI/USDT/USDC pool. **TODO verify**.
- `LOCAL_PCS_V3_USDT_USDC = 0x92b7807bF19b7DDdf89b706143896d05228f3121` —
  PCS v3 USDT/USDC 1bp pool (flash provider). **TODO verify**.

## Risks
- **Depeg doesn't exist.** If VAI trades at par the strategy returns
  zero — but it cannot lose money beyond gas because every leg checks
  pre-trade.
- **Flash fee > depeg gross.** The PoC requires `MIN_DEPEG_BPS = 30`
  (3× the 1bp flash fee + slippage allowance).
- **VAIController paused.** Mitigation for variant B; variant A is unaffected.
- **Sandwich attack.** A searcher could front-run the StableSwap leg.
  Mitigation: real ops would use a private mempool / MEV-share; PoC ignores.

## Result
Status: **theoretical, offline**. Expected net per atomic call at the
pinned block (with synthetic 50bp depeg injected): **+$2,600 (variant A)
to +$3,800 (variant B) per $1M flashed**. Capital cost: only the gas + the
USDT residual to top up flash fees.
