# B03-02 — slisBNB · Lista CDP recursive leverage loop

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

Lista is the **only large CDP system on BSC that accepts an LST as direct
collateral**: slisBNB is its flagship vault asset and earns the slisBNB
staking yield while collateralising lisUSD debt.

If we

1. deposit `slisBNB` into a Lista vault,
2. mint `lisUSD`,
3. swap that lisUSD into `BNB` (via PCS v3 / Wombat),
4. stake the BNB back into `slisBNB` via `IListaStakeManager.deposit`,
5. re-deposit the new slisBNB into the same vault,

…we build recursive exposure to slisBNB's staking APR while paying the
Lista borrow rate on lisUSD. With a max-LTV of `~80%` on slisBNB, after
N rounds the effective leverage is `1/(1-0.8) = 5x` (geometric limit).

**PnL signature:** `slisBNB_apr × 5 − lisUSD_borrow_rate × 4` over the
holding period, plus any AMM slippage paid on the lisUSD→BNB hop on the
way in (recovered linearly via the staking yield).

## Mechanism stack

1. **Lista CDP** (Interaction proxy) — `deposit(slisBNB) + borrow(lisUSD)`.
2. **PCS v3 lisUSD/USDT + USDT/BNB** (or Wombat lisUSD/BNB-LP) to swap
   minted lisUSD into BNB.
3. **`IListaStakeManager.deposit{value: bnb}()`** — mint fresh slisBNB
   at the canonical exchange rate (no AMM slippage).
4. Loop N rounds (3 is usually >95% of the geometric leverage limit).

## Why this is interesting

- **Pure-LST CDP loop**: every other large CDP on BSC (Venus VAI, Avalon)
  uses plain BNB/BTCB as collateral. Lista is unique on BSC in letting
  you double-dip slisBNB yield + lisUSD borrow.
- **AMM-free re-staking**: step 4 uses the LST mint at canonical rate,
  not an AMM swap — so the loop's slippage cost is bounded to a single
  lisUSD→BNB hop per round, not two.
- **Atomic but capital-efficient**: with 1 USD seed we get 5 USD of
  slisBNB exposure earning staking yield.

## Address verification

- `BSC.slisBNB = 0xB0b84D...4A1B` — verified.
- `BSC.LISTA_STAKE_MANAGER = 0x1adB95...77fE6` — verified canonical
  StakeManager (BNB↔slisBNB conversion source of truth).
- `BSC.LISTA_INTERACTION = 0x1A0D55...CBE0` — **TODO verify**;
  `deposit/borrow` selectors are best-effort. Once a real fork RPC is
  available, decode the live ABI and pin the proxy.
- `BSC.PCS_V3_ROUTER = 0x13f4EA...68Dd4` — verified.

## Status & PnL

- **Status:** offline-draft. Compiles; the live run requires a real
  Interaction ABI + a fork block on BSC.
- **PnL model:** with `slisBNB_apr = 3.2%`, `lisUSD_borrow = 2.0%`,
  3 loop rounds give ~`3.2 × 4 − 2.0 × 3 = 6.8%` net APR on seed
  collateral. AMM slippage budget per round: ~10 bp; absorbed by the
  first ~12 days of yield.

## TODO

- Validate `IListaInteraction.deposit/borrow/withdraw/payback` selectors.
- Replace synthetic exchange-rate calls with on-fork `convertSnBnbToBnb`.
- Confirm Lista's max-LTV / liquidation parameters for slisBNB market
  (the 80% LTV assumption above is best-effort).
- A real keeper would lower LTV target to ~70% to keep a healthy buffer.
