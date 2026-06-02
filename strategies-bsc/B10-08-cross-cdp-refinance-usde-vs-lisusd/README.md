# B10-08 — Cross-CDP refinance: USDe short-term borrow vs lisUSD long-term debt

## Family

B10 · Cross-stablecoin CDP basis (refinance branch).

## Thesis

A lisUSD CDP user pays a stickily-high stability fee (Lista SF, historically
6-8 % APR) on their long-dated debt. Venus, separately, lists USDe as a
borrowable market whose rate is set by the Venus IRM curve. Because USDe
supply on Venus is fed by Ethena cash-and-carry funding flows, the Venus
USDe borrow rate often dips well below the Lista SF for multi-week
windows — even though both debts are denominated in the same $-target.

B10-08 captures this **debt-side basis** by *refinancing* a slice of the
Lista lisUSD debt with a fresh Venus USDe borrow:

1. Deposit slisBNB into Venus as Venus-side collateral (the user can
   sponsor the same asset they already pledged to Lista because Venus
   accepts slisBNB independently).
2. Borrow USDe on Venus at the (cheaper) Venus rate.
3. Swap USDe → lisUSD via PCS Stable.
4. Use the swapped lisUSD to `payback()` the Lista debt by `REFINANCE_SLICE`.

The position runs while the spread holds, then unwinds (mint Lista again,
swap, repay Venus) when the spread crosses or the hold horizon expires.
This is symmetric to B10-04's rotation but happens at the **debt** layer:
B10-04 rotates the asset you hold; B10-08 rotates the asset you owe.

## Mechanism stack (3 distinct mechanisms)

1. **Lista CDP** — `payback(slisBNB, lisUSD)` to reduce long-dated debt
   liability; mirror `borrow()` on unwind.
2. **Venus borrow market** — slisBNB collateral, USDe debt at the IRM
   rate. This is the second CDP-class debt and the source of the
   refinance savings.
3. **PCS StableSwap** — USDe ↔ lisUSD swap so the Venus debt can be
   applied to the Lista debt (and reversed at unwind). The swap drag is
   the dominant cost line.

## Why this is genuinely B10 (and not B05 / B10-01)

- B05 (USDe peg flash arb) is an atomic peg-restoration play; never
  touches a CDP debt.
- B10-01 captures the spread by *minting* the cheaper CDP stable. B10-08
  does the opposite: the user already holds a Lista CDP debt, and pays it
  down with a Venus-funded credit. The structural difference is that no
  new lisUSD is created — debt simply moves between two CDP issuers. This
  is the natural defense play for any user with a sticky Lista position
  who wants to surf Venus rate dips.

## Block layout (hold + unwind)

1. `t = 0` — deposit `SLISBNB_COLLATERAL` on Venus; borrow `REFINANCE_SLICE`
   USDe; swap USDe → lisUSD; `payback(slisBNB, lisUSD)` for the same slice
   on Lista.
2. `t = 0..HOLD_DAYS` — Venus accrues at `VENUS_USDe_borrow_rate`; Lista
   no longer accrues SF on the refinanced slice. Net saving =
   `(LISTA_SF − VENUS_USDe_rate) × slice × T`.
3. `t = HOLD_DAYS` — mint `REFINANCE_SLICE` lisUSD on Lista again, swap to
   USDe, repay Venus borrow + cost, withdraw Venus collateral.

## Status & PnL

- **Status:** offline-only PoC. The Venus USDe market (`vUSDe`) does not
  have a canonical BSC address in `BSC.sol` at scaffold time; the on-fork
  branch falls back to the offline accounting.
- **PnL model** (`slice = $400k`, `T = 21d`, spread = 720 − 480 = 240 bp):
  - Funding saved: `400_000 × 240 bp × 21/365 = $552`.
  - PCS swap drag entry: `400_000 × 4 bp = $160`.
  - PCS swap drag exit: `400_000 × 4 bp = $160`.
  - Net 21-day PnL ≈ **$232 on $400k slice** (~1.0 % APR on slice; ~0.6 %
    APR on the $800k Lista debt that funds the strategy).
- The PnL is small in absolute terms, but the strategy compounds with
  any other lisUSD-side incentive (Lista MasterChef boost, PCS LP, Pendle
  YT) because the user retains lisUSD exposure throughout.

## Address / ABI verification

- `BSC.LISTA_INTERACTION`, `BSC.PCS_STABLE_ROUTER`, `BSC.slisBNB`,
  `BSC.lisUSD`, `BSC.USDe` sourced from `BSC.sol`.
- `LOCAL_VUSDE` is a placeholder for the Venus USDe market; promote to
  `BSC.sol` once the BSC Venus isolated-pool deployment is canonicalised.

## TODO

- Pin `LOCAL_VUSDE` once Venus ships a canonical USDe market on BSC.
- Replace constants `LISTA_SF_BPS` and `VENUS_USDE_BORROW_BPS` with
  fork-time reads (`ILisUSDController.stabilityFee` and the Venus
  borrowRatePerBlock).
- Wire up a *threshold-trigger* rebalance: when the spread crosses, flip
  the position to "borrow lisUSD on Lista, swap to USDe, repay Venus" —
  the symmetric direction, identical to B10-04 but at the debt layer.
- Composability check: layer the refinance on top of a Lista MasterChef
  lisUSD stake (the user would have done this with the freed lisUSD
  anyway); the marginal alpha is the funding-spread capture alone.
- Stress test against the case where slisBNB price drops > 15 % during
  the hold and triggers a Venus liquidation; size the slisBNB
  collateral buffer accordingly.
