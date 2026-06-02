# B10-02 — USD1 short-term premium capture via PCS v3 flash

## Family

B10 · Cross-stablecoin CDP basis (peg-deviation branch).

## Thesis

**USD1** is World Liberty Financial's BSC-issued stable
(`0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d`). Unlike Lista lisUSD or Venus
VAI, USD1 is **fiat-backed and issuer-mintable** — there's no AMM-mediated
mint path for retail. New supply only enters the chain when WLFI's treasury
issues it, and that issuance is **lumpy**: weeks of no new supply followed by
a single large mint.

In the lumpy regime, USD1 routinely trades at **+30 to +120 bp above $1** on
PancakeSwap because thin pool depth and asymmetric demand (BSC users wanting
USD1 for political-narrative reasons) pin the AMM price above the off-chain
backing.

When the AMM premium is wider than the round-trip swap cost back through a
liquid stable (USDC), an atomic **flash-buy-cheap, sell-rich** loop captures
the spread without leaving any USD1 inventory.

## Mechanism stack

The premium exists because v3 is the **deep** USD1 venue (where every retail
buyer lands). Smaller venues — PCS v2 `USD1/USDC` or Wombat `USD1/USDT` —
trail the v3 mark. The arb buys USD1 on the lagging venue at par and sells
it on PCS v3 at the premium.

1. **PCS v3 flash** USDC notional from the deep `USDC/USDT` 0.01 % tier
   (flash fee = 1 bp). This pool is **not** the leg we're trading against,
   so the flash doesn't move the premium.
2. **PCS v2 swap** `USDC → USD1` on the v2 `USD1/USDC` pool at the **par
   price** (no v3 retail premium because v2 is the laggy venue). Pay $1.00
   of USDC, receive ~0.9995 USD1 (5 bp v2 fee).
3. **PCS v3 swap** `USD1 → USDC` on the `USD1/USDC` v3 pool at the
   **premium**. Each 1 USD1 sells for ~1.008 USDC minus the v3 fee tier.
4. **Repay flash** = `notional + 1 bp` to the flash source pool.

Net atomic PnL:

```
pnl = notional × (premium_bps - v2_fee_bps - v3_fee_bps - flash_fee_bps)
```

For an 80 bp v3 premium with 5 bp v2 fee, 1 bp v3 fee, 1 bp flash fee, the
strategy nets **~+73 bp atomic on the flashed notional**. On a $5m flash,
that is **~$36k per pop**.

## Why this is genuinely a "B10" play (not just a B07 cross-DEX arb)

The PCS v7-style cross-DEX scanner doesn't naturally surface USD1 because the
asset is too new and illiquid for the family's pool registry. The B10 angle
is the **issuer-mint-asymmetry**: the premium exists precisely because USD1
has no on-chain CDP path back to $1, unlike VAI / lisUSD. That asymmetry —
"some stables have a venue to par, some only have an issuer to par" — is the
defining B10 surface.

## Address verification

- `BSC.USD1 = 0x8d0D...0B0d` — **TODO verify**. The BSC.sol comment marks
  this as TODO; placeholder behaviour is preserved (token is treated as a
  generic 18-decimal stable priced at $1 in the base oracle).
- `BSC.USDC = 0x8AC7...580d` — verified.
- PCS v3 USDC/USDT 0.01 % pool address is resolved at runtime via
  `factory.getPool(USDC, USDT, 100)`.
- PCS v3 USD1/USDC pool fee tier is unknown ex-ante; we probe 100, 500,
  2500 in order and pick the first non-zero address.

## Status & PnL

- **Status:** offline-first. Compiles; live execution depends on real USD1
  pool deployment + a fork block where the premium > 50 bp.
- **PnL model:** `notional = $5_000_000`, atomic premium = 80 bp, total
  swap + flash drag = 7 bp. Net atomic = `5_000_000 × 73 bp = $36_500`.
- Offline path simulates the swap legs by direct balance manipulation and
  asserts the printed PnL block matches the model within rounding.

## TODO

- Confirm canonical USD1 token address with WLFI / BscScan.
- Add a pool-depth ceiling to bound `notional` so the swap slippage doesn't
  eat the premium. (Currently `notional` is hardcoded; in production it
  would be `min(flash_pool_cash, sqrt(K) × delta_threshold)`.)
- Promote `IPancakeV3Quoter` interface so we can resolve the actual on-chain
  premium instead of assuming 80 bp.
- Add a sister strategy that goes the other way (USD1 discount, atomic mint
  of lisUSD/VAI to fill the gap) once USD1 redemption hook is documented.
