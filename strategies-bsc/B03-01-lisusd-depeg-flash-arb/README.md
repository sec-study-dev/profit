# B03-01 — lisUSD depeg atomic arb via PCS v3 flash + Lista payback

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

Lista DAO's `lisUSD` is an over-collateralised CDP stable. The protocol's
peg is **soft** — there is no PSM that guarantees `1 lisUSD = 1 USDT`. The
peg-defense mechanism is *indirect*: arbitrageurs who hold open vaults can
buy discounted lisUSD on PancakeSwap and use it to `payback` their own debt
(or any CDP via the Interaction contract). 1 lisUSD of debt always cancels
$1 of borrowed value, so buying lisUSD at e.g. $0.997 and using it to repay
debt is a **risk-free 30 bp credit**.

Observed pattern on PancakeSwap v3 `lisUSD/USDT` and Wombat `lisUSD/USDT`
pools (block range Q3 2024 onward): lisUSD repeatedly trades 20-100 bp
below USDT for hours at a time during BNB drawdowns (CDP holders panic-sell
their freshly-minted lisUSD).

## Mechanism stack

1. **PancakeSwap v3 flash** the discounted-side asset (USDT) from the
   `USDT/USDC` 1bp pool — flash fee = pool fee = 1 bp on USDT.
2. **PCS v3 swap** USDT → lisUSD in the `lisUSD/USDT` pool at the depegged
   price (we collect more than 1 lisUSD per 1 USDT).
3. **Lista `payback`** — call `IListaInteraction.payback(slisBNB, amount)`
   on a vault we pre-opened with a tiny amount of debt. This burns lisUSD
   at par against debt, so 1 lisUSD discharges $1 of debt.
4. **Withdraw collateral** worth the par amount of repaid debt (slisBNB)
   and swap back to USDT to close the flash loan + capture the spread.

Net atomic PnL ≈ `(1 - PCS_lisUSD_price) × notional − PCS_flash_fee
− two AMM hops`.

## Why this is "real" (not a generic stable arb)

Generic stable arb requires the depegged side to also have a venue back to
par. lisUSD has **no PSM**, so the only honest path back to $1 is **CDP
debt repayment**. This means every successful arb actually *retires*
lisUSD debt — i.e. the strategy is structurally part of Lista's peg defense
not just a parasite on AMM imbalance.

## Address verification

- `BSC.lisUSD = 0x0782b6...41E5` — verified, canonical lisUSD ERC-20.
- `BSC.LISTA_INTERACTION = 0x1A0D55...CBE0` — **TODO verify**; placeholder
  selector signatures in `IListaInteraction` are MakerDAO-style guesses;
  needs reconciliation against the deployed Interaction proxy ABI.
- `BSC.PCS_V3_FACTORY = 0x0BFbCF...1865` — verified.
- PCS v3 `lisUSD/USDT` pool address derived at runtime via
  `factory.getPool(lisUSD, USDT, fee)`.

## Status & PnL

- **Status:** offline-draft. Compiles, but live execution depends on real
  pool addresses + a fork block at which lisUSD is actually depegged.
- **PnL model:** modelled at `+25 bp net` of notional (50 bp gross discount
  − 1 bp flash fee − ~2 bp two-hop slippage − tiny payback fee). On a
  $1m flash, that is **~$2.5k atomic profit per opportunity**.

## TODO

- Validate `IListaInteraction.payback` selector against deployed proxy.
- Replace synthetic peg setup in PoC with a real fork block where the
  lisUSD/USDT pool shows ≥30 bp discount.
- Add a `redemption` variant once Lista exposes a public redemption queue
  (currently lisUSD has no Maker-style DSR / Dai-redemption path).
