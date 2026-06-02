# B12-06: enzoBTC dual-venue basis — Lista Lending vs Avalon

## Mechanism (3-mech)
1. **Lorenzo enzoBTC** — BTCB-backed BTC restake token issued by
   Lorenzo Protocol; mints 1:1 against BTCB, earns native Babylon
   restake yield (~2 % APY) and project points.
2. **Lista Lending market for enzoBTC** — supply enzoBTC and capture
   the higher supply APY (Lista incentive emission targets BTC
   collateral to bootstrap the market; ~4.5 % APY at the pinned block).
3. **Avalon Lending Pool** — supply matching enzoBTC and borrow USDX.
   USDX -> USDT -> BTCB -> mint enzoBTC -> re-supply to **Lista** (not
   Avalon). The basis edge is the supply-APY differential between the
   two venues; Avalon's role is the borrow base, Lista's role is the
   income base.

## Why it composes
- A single asset (enzoBTC) sits in two lending markets simultaneously,
  arbing the venue-by-venue APY divergence.
- The recursive loop routes each new unit of enzoBTC to whichever
  market offers higher supply APY net of borrow cost, capturing the
  full incentive program.
- BTC delta is preserved across the entire structure (no shorts).

## Strategy steps (12 BTC notional, 45-day horizon)
1. Mint 12 enzoBTC from BTCB.
2. Supply 6 enzoBTC to Lista (income leg).
3. Supply 6 enzoBTC to Avalon (funding leg).
4. Borrow USDX from Avalon at safety = 90 % availableBorrowsBase.
5. USDX -> USDT -> BTCB -> enzoBTC; supply newly minted enzoBTC to
   **Lista** (not Avalon — captures the APY edge).
6. Hold 45 days; redeem proceeds from both markets, repay USDX.

## PnL math (12 BTC principal, 45-day horizon, BTC = $65k)
Indicative rates:
- enzoBTC native restake APY: 2.0 % (on all principal, delta-1).
- Lista supply APY for enzoBTC: 4.5 %.
- Avalon enzoBTC supply APY: 1.8 %.
- Avalon USDX borrow APR net of incentives: 1.5 %.
- Swap drag: ~30 bp on the borrow leg per loop.

Blended carry:
- Lista income (75 % of net principal after recycling): +3.38 % APY.
- Avalon spread (25 % of principal): +0.07 % APY.
- Swap drag: -0.30 % APY.
- enzoBTC restake on all 12 BTC: +2.00 % APY.
- **Total: +5.15 % APY.**

45-day carry: 5.15 * 45/365 = **+0.635 %** on principal.
Dollar PnL: 12 BTC * $65k * 0.635 % = **~ +$4,950**.

Gas: 2 supply + borrow + multi-hop + Lista supply ≈ 1.8M gas, ~$1.10.

## Block pinned
**47_900_000** (early-2025; assumes Lorenzo enzoBTC live and Lista
Lending listing BTC). Re-pin once verified.

## Addresses used
- `LOCAL_ENZOBTC = 0x6Ec1c8A0...` — enzoBTC ERC20 (TODO verify).
- `LOCAL_ENZOBTC_MINTER = 0x...B12061` — Lorenzo minter (TODO verify).
- `LOCAL_USDX = 0xf3527eF8...` — Avalon USDX (TODO verify).
- `BSC.AVALON_LENDING_POOL` — Avalon Aave V3 fork.
- `BSC.LISTA_LENDING` — Lista Lending (TODO verify enzoBTC listing).
- `BSC.PCS_V3_ROUTER` — PCS v3 SwapRouter.

## Risks
- Lista may not list enzoBTC at the pinned block. Mitigation: PoC
  guards Lista calls and falls back to a single-venue Avalon-only
  strategy (lower APY).
- enzoBTC issuance pause kills the restake yield leg.
- Avalon USDX borrow rate spike narrows the basis. Mitigation: hold
  horizon kept short (45 days) so rate risk is small.

## Result
Status: **theoretical** (multiple TODO-verify; PoC guards every
external call with try/catch). Expected PnL: **+0.5 - 0.8 % over
45 days on 12 BTC principal**.
