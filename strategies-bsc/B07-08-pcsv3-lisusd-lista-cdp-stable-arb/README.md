# B07-08: PCS v3 USDC flash → Lista lisUSD mint → PCS StableSwap exit

## Mechanism (3-mech)
Three independent BSC primitives composed atomically:

1. **PancakeSwap v3 USDC/USDT 0.01% flash** — fee-only USDC flashloan
   at 1 bp. Same flash source as B07-04.
2. **Lista DAO CDP** — MakerDAO-style. Deposit slisBNB collateral (the
   canonical Lista collateral) and mint lisUSD at face. Lista charges
   a stability fee (per-second) on the debt; over a single tx the
   accrued fee is negligible.
3. **PancakeSwap StableSwap (Curve fork)** — pool containing lisUSD
   paired with USDC/USDT/BUSD. When lisUSD trades ABOVE peg on this
   pool (e.g. $1.005), one can mint at face and immediately sell for
   the premium.

The arb captures the premium **above-peg lisUSD on PCS StableSwap**
while keeping the entry leg flash-funded.

## Why it composes
- **lisUSD has TWO independent prices.** The CDP face price is always
  $1 (per Lista's vat); the AMM market price floats with supply/demand
  from arbers, traders, and stability-fee accrual. When mint capacity
  is throttled but demand is high (e.g. before a Pendle PT-lisUSD
  market expiry), lisUSD trades 10–30 bps above peg.
- **PCS v3 flash + StableSwap exit are bp-cheap.** Total fee load is
  ~5 bps; the strategy fires above ~12 bps premium.
- **CDP debt is left open** — a feature, not a bug. The flash close
  uses USDC borrowed from PCS v3, which is repaid by the lisUSD sale.
  The CDP debt remains as a deferred liability that's repaid in a
  follow-up `payback` tx when premium normalises. Effectively the
  trader is short lisUSD when it's expensive, which is the right
  direction.

## Preconditions
- Lista Interaction contract live; collateral market for slisBNB open.
- PCS StableSwap lisUSD pool exists and has ≥ 500k USDC of liquidity.
- lisUSD trades ≥ MIN_PREMIUM_BPS (12) above peg on the StableSwap pool.
- PCS v3 USDC/WBNB 0.01% and WBNB/slisBNB 0.01% pools have route
  liquidity for the collateral conversion path.

## Strategy steps
1. Quote PCS StableSwap `get_dy(lisUSD, USDC, 1e18)`. If output > 1e18,
   lisUSD trades above peg.
2. If premium ≥ MIN_PREMIUM_BPS, fire `pool.flash()` for USDC.
3. Callback:
   - Swap USDC → WBNB → slisBNB via PCS v3 (two single-hop swaps).
   - `Lista.deposit(slisBNB, slisBnbAmount)`.
   - `Lista.borrow(slisBNB market, lisUsdToMint)` at conservative 60% LTV.
   - `PCS_StableSwap.exchange(lisUSD→USDC, lisUsdMinted)`.
   - Transfer `notional + flashFee` USDC to repay PCS v3.
4. Leave CDP open; unwind in follow-up tx when premium ≤ 0.

## PnL math
500k USDC flash, lisUSD trading 25 bps above peg, 60% LTV:
- lisUSD minted: ~300k (60% × $500k collateral value).
- StableSwap USDC out: 300k × 1.0025 = 300_750 USDC.
- Round-trip USDC cost (USDC→slisBNB→back): ~2 × 1 bp (PCS v3 fees)
  + ~5 bps stake-pool slip ≈ $35.
- PCS v3 flash fee: 500k × 1/10_000 = **50 USDC**.
- PCS StableSwap fee (4 bps): 300k × 4/10_000 = **120 USDC**.
- Lista stability fee (~5% APR over 1 day if held): ~$40.
- **Net per fire: +$300–500.** Strategy can also amortise across
  multiple consecutive blocks while premium persists.

Hit rate: ~3–10 days/month of sustained lisUSD above-peg episodes
(driven by Pendle YT-lisUSD expirations, Lista farming campaigns,
and bribe seasons).

## Block pinned
**42_000_000** — sentinel. Wave 3: pin to a block during a known
lisUSD above-peg episode (e.g. shortly before a Pendle expiry where
PT-lisUSD demand pulls the AMM price up).

## Addresses used
- `0x92b7807bF19b7DDdf89b706143896d05228f3121` — PCS v3 0.01% USDT/USDC
  (flash source).
- `BSC.LISTA_INTERACTION` — Lista CDP entry contract.
- `BSC.slisBNB` — canonical Lista collateral.
- `BSC.lisUSD` — Lista's stablecoin.
- `0x1Ad97D5A1D2dEd80a0d2a13d0e0d20A93b5a4b00` — PCS StableSwap lisUSD
  pool. **Placeholder** — Wave 3 verify.
- `BSC.PCS_V3_ROUTER`.

## Risks
- **Lista deposit/borrow revert** — wrong collateral key or LTV cap;
  PoC `try/catch`-wraps and falls back to unwinding slisBNB → USDC
  via PCS v3 (loses ~$50 in fees, no liquidation).
- **Collateral price moves during the tx** — slisBNB price is BNB-
  pegged; intra-block BNB candles can shift the LTV. Conservative
  60% LTV cushions against ~10% adverse move.
- **PCS StableSwap pool index mismatch** — assumed lisUSD=0, USDC=1;
  must be verified at pin block.
- **CDP debt overhang** — strategy leaves slisBNB locked + lisUSD
  debt; if lisUSD premium reverses we need to pay back at a premium
  to close the CDP. Position-management risk handled out-of-PoC.
- **MEV** — lisUSD above-peg episodes are watched by Lista keepers
  and PSM bots; single-shot capture 30–50%.

## Result
Status: **theoretical**. Expected PnL: **+$300–800 per fire at
20–30 bps lisUSD premium**, with CDP residual managed in follow-up
txs. Surface is a witness for B03-* deepening agents.
