# B03-05 — Lista clip-auction keeper (lisUSD -> discounted slisBNB)

## Family

B03 · Lista lisUSD CDP mechanism arbitrage.

## Thesis

Lista DAO inherits Maker's `dog → clip` liquidation pipeline. When a
slisBNB-collateralised CDP slips below its safety LTV, anyone may call
`dog.bark()`, which moves the bad position into a `clipper` Dutch
auction. Each clipper sells the seized slisBNB at a price that **starts
at oracle, decays at a fixed rate, and accepts lisUSD as payment**. The
lisUSD received is `vow`-burned against the system's bad debt.

A keeper that arrives within the first few minutes of an auction can
buy slisBNB at a 1-5% discount to oracle and immediately dump it to
WBNB/USDT for an atomic profit. The trade is fully self-financed via a
PCS v3 flash because lisUSD trades 1-for-1 against USDT in the deep
PCS v3 1bp pool.

## Mechanism stack

1. **PCS v3 flash** USDT from `USDT/USDC` 1bp pool.
2. **PCS v3 swap** USDT → lisUSD (1bp pool).
3. **Lista Clipper take** — bid lisUSD into an active auction, receive
   slisBNB at the auction's current Dutch price.
4. **PCS v3 swap** slisBNB → WBNB (5bp LST pool) → USDT (5bp main pool).
5. **Repay** the PCS v3 flash.

## Why this is interesting

- **Pure Lista-specific mechanism**: no other family member touches the
  clipper. The discount is paid by the system, not by other LPs.
- **Atomic & self-financing**: no inventory required, single
  block-bounded tx, MEV-friendly.
- **Asymmetric reward**: clip discount stacks deterministically (~3% at
  the early window) regardless of the broader market, so the keeper
  bid floor is set by hop fees only (~12 bp).

## Address verification

- `BSC.PCS_V3_FACTORY` — verified.
- `BSC.lisUSD` / `BSC.USDT` / `BSC.slisBNB` / `BSC.WBNB` — verified.
- `LISTA_CLIPPER` — **TODO**: not yet in `BSC.sol`. Lista's deployed
  clipper proxy needs to be resolved against the on-chain
  `IListaInteraction.ilks(slisBNB).clip` slot.

## Status & PnL

- **Status:** offline-draft. The Clipper `take()` call is sketched in
  comments; the offline model captures the discount as a 3% boost on
  the slisBNB received vs. the lisUSD paid.
- **PnL model:** on a $500k clip take, capturing a 300 bp discount and
  paying ~16 bp in fees nets ~284 bp × $500k = **~$14k per auction**.

## TODO

- Resolve the Clipper proxy address for the slisBNB ilk on BSC.
- Pull the live `ilk.clip.tip / chip / buf` parameters; the actual
  early-window discount may differ materially from 300 bp.
- Add an `IListaClipper.take()` callback path that lets the keeper
  source the lisUSD inside the take-callback (zero pre-flash variant).
- Cross-link with B06-04 (VAI depeg flash) — same keeper infra.
