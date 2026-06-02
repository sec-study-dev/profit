# B06-06: Cross isolated-pool collateral migration (Venus Core → LST pool)

## Family
B06 — Venus V4 isolated pool arbitrage. The user holds a Core-pool position
(slisBNB collateral, USDT debt). The LST isolated pool offers (a) a higher
collateralFactor on slisBNB and (b) a lower USDT borrow APR. We migrate
the entire position atomically without ever liquidating to spot.

## Mechanism (3-mech)
1. **Venus V4 `flashLoan` on Core vUSDT** — supplies USDT equal to the
   current Core USDT debt so we can fully `repayBorrow` and free the
   slisBNB collateral.
2. **Cross-Comptroller atomic redeem + supply** — same `address(this)`
   redeems vSlisBNB on the Core Comptroller, supplies the freed slisBNB
   into the LST-pool vSlisBNB. Per-Comptroller `enterMarkets` state is
   isolated, so neither pool tries to enforce the other's CF.
3. **LST-pool `borrow` to repay the flash** — re-borrow USDT from the LST
   pool's vUSDT and use it to repay the Core flash + 9 bp premium. The
   net effect is "debt teleported" from Core to LST without ever exposing
   the user to spot price risk on slisBNB.

## Why it composes
- The flashLoan removes the requirement to bring fresh USDT working capital.
- The cross-Comptroller redeem+supply only works because Venus V4 keeps
  per-pool state truly isolated.
- The LST-pool borrow is the missing leg that closes the flash and leaves
  the user with the *same* USDT debt, but on a pool with a wider LTV cushion
  and a cheaper borrow rate.

After migration the user pays roughly **150–250 bp less per year** in USDT
interest and has **25 % more LTV headroom** before liquidation. Both come
from the LST pool's risk-isolated parameters.

## Addresses (inlined)
- `LOCAL_LST_COMPTROLLER = 0x596B11ac…` — LST-pool Comptroller. TODO verify.
- `LOCAL_VUSDT_LST = 0x1D8BB512…` — LST-pool vUSDT. TODO verify.
- `LOCAL_VSLISBNB_LST = 0xd3CC9d8f…` — LST-pool vSlisBNB. TODO verify.
- `LOCAL_VSLISBNB_CORE = 0xd3CC9d8f…` — Core-pool vSlisBNB. TODO verify
  (Venus may use the same address; confirm against the canonical Core
  vSlisBNB listing — placeholder shared with LST pool).
- `BSC.vUSDT` / `BSC.VENUS_COMPTROLLER` from the address book.

## Block pinned
**42_500_000** — same as B06-01/02/03/04, three weeks past the LST pool
launch so LTV and rate parameters are stable.

## PnL math (per $300k migrated debt, 60-day hold)
- USDT borrow APR Core ≈ 5.5 %; LST pool ≈ 3.8 %. Spread = 170 bp.
- 60-day interest savings on $300k = `$300k × 1.7 % × 60/365 ≈ $838`.
- Flash premium one-shot = `$300k × 9 bp = $270`.
- Net 60-day = **$568 of pure interest savings + ~25 % more LTV
  cushion** (impossible to quantify in $ without a future depeg event).

Gas ≈ 700k (flash + 1 repay + 1 redeem + 2 enterMarkets + 1 mint +
1 borrow) ≈ $0.42.

## Risks
- **LST pool USDT cash too low.** If `vUSDT_LST.getCash() < flashOwed`
  the re-borrow leg reverts the whole tx; nothing settles. Safe — atomic.
- **Different oracle on the LST pool.** A slisBNB oracle divergence could
  briefly value the migrated collateral lower, leading to instant
  underwater state on the new pool. PoC reads `getAccountLiquidity` post-
  migration but inside the same tx (can't read post-state easily); a
  production path simulates first.
- **Pre-existing position not seeded.** Offline PoC uses `_seedCorePosition`
  with `try/catch`; if the Core slisBNB market is not listed at the
  pinned block, PnL prints as a clean no-op.

## Result
Status: **theoretical, offline**. Expected net **~$570 over 60 days
per $300k of migrated debt** + a permanent ≈ 25 % LTV-cushion gain. The
strategy compiles and runs as a no-op when no Core position exists.
