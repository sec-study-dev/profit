# B03-03 — lisUSD ↔ USDe cross-CDP carry basis

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

`lisUSD` and `USDe` are two different "synthetic dollar" mechanisms with
**uncorrelated cost-of-issuance**:

- **lisUSD** = collateral × Lista borrow rate. The borrow rate is a
  function of slisBNB price and Lista's `Jug`-style stability fee.
  It moves slowly and rarely exceeds 3-4% APR.
- **USDe** = (delta-neutral ETH/BTC short on CEXes) × perp funding.
  Funding is volatile, sometimes negative (USDe holders *receive* yield
  via sUSDe), sometimes briefly above 20% APR during euphoria periods.

These two costs are uncorrelated, so the **basis** lisUSD-borrow-rate
minus USDe-implied-cost (negative sUSDe APY = the cost of being USDe
short) opens up regularly. When `Lista_borrow_rate < -sUSDe_APY`, we can:

1. Open a Lista vault with slisBNB collateral.
2. Borrow lisUSD cheaply.
3. Swap lisUSD → USDe on PCS v3 (or Wombat).
4. Stake USDe → sUSDe to capture the funding yield.

Holding-period PnL = `sUSDe_APY × holding_period − Lista_borrow_rate ×
holding_period − 2 × swap_slippage`. With sUSDe at 12% APY and Lista at
2.5% APY, that is **~9.5% annualised** on the lisUSD notional, on top of
whatever the slisBNB collateral itself earns (3.2% APR).

## Mechanism stack

1. **Lista CDP** — deposit slisBNB, mint lisUSD.
2. **PCS v3 lisUSD/USDT → USDT/USDe** — two-hop swap, both legs are
   stable-stable on tight pools.
3. **sUSDe deposit** — ERC-4626 wrapper, `sUSDe.deposit(USDe, recipient)`.
4. **Carry** — held positionally over `HOLD_DAYS`.
5. **Unwind** — `sUSDe.redeem` (subject to Ethena cooldown), swap back to
   lisUSD, `payback` the debt, withdraw slisBNB.

## Why this is interesting

- **Two stable-dollar mechanisms in opposition**: lisUSD pays for being
  long, USDe pays you for being short. Whenever sUSDe APY > Lista borrow
  rate, the basis is real, and it is uncorrelated with CEX/DEX trades.
- **Cross-chain mint awareness**: USDe on BSC is a LayerZero OFT, not
  natively mintable. We rely on the BSC-side PCS v3 USDe market for
  entry/exit liquidity. Currently shallow (~$5m); strategy is sized to
  fit within ~50 bp slippage.

## Address verification

- `BSC.lisUSD = 0x0782b6...41E5` — verified.
- `BSC.USDe = 0x5d3a1F...ef34` — **TODO verify** (placeholder USDe BSC
  OFT address; needs confirmation against Ethena's official deployment).
- `BSC.sUSDe = 0x211Cc4...fE5d2` — **TODO verify** (placeholder; sUSDe
  may not exist as a separate BSC OFT — confirm against Ethena docs).
- `BSC.LISTA_INTERACTION = 0x1A0D55...CBE0` — **TODO verify**.

## Status & PnL

- **Status:** offline-draft. Address validity is the main blocker — at
  least `BSC.USDe` and `BSC.sUSDe` are marked TODO verify in the address
  book.
- **PnL model:** at 12% sUSDe APY, 2.5% Lista borrow, 60 days hold, on a
  $100k lisUSD notional → **~$1.6k carry profit**.

## TODO

- Verify USDe + sUSDe canonical BSC OFT addresses.
- Confirm whether sUSDe ERC-4626 surface is exposed on BSC or only on
  Ethereum (if only on Ethereum, this strategy migrates to F-family).
- Implement Ethena 7-day cooldown handling in the unwind path.
- Replace synthetic borrow-rate model with `IListaInteraction` /
  `Jug`-style stability fee reads from a live fork.
