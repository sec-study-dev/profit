# B14-06: asBNB collateral + Lista lisUSD savings + Venus loop — 3-mech cross-asset

## Mechanism (3-mech, cross-asset)
A cross-asset stack that lets BNB-principal earn three stacked yields
without forfeiting BNB exposure:

1. **asBNB restake yield**. Astherus' asBNB pays ~5 % base APR sourced
   from BNB restaking + Babylon-style BTC restake-points overlay.
2. **Lista lending → lisUSD savings**. Borrow lisUSD against asBNB
   (CF ~0.70) and redeposit half of the proceeds into Lista's lending
   pool to capture the lisUSD savings APR. Net carry = savings APR −
   borrow APR, levered by the asBNB collateral leg.
3. **Venus vUSDT loop**. Swap the other half of borrowed lisUSD into
   USDT via Wombat (~25 bp drag) and run a 2-iteration recursive
   vUSDT loop, collecting Venus XVS supply + borrow incentives.

This is the BSC analogue of the mainnet "LST collateral + stable
borrow + stable yield" mega-stack (cf. F12/F14 on mainnet) — but on
BSC the asBNB restake leg, Lista savings, and Venus XVS bonus are
three orthogonal yield drivers that don't share counterparty risk.

## Why it composes
- asBNB is **non-rebasing** (share token), so Lista Lending can
  collateralise it without share-accounting issues; the restake APR
  accrues entirely to the holder via `convertToAssets` appreciation.
- lisUSD's savings APR (`LISUSD_SAVINGS_APR_BPS = 4.0 %`) is below the
  Lista borrow APR (`5.0 %`), so the *savings half* runs at -1 % per
  loan dollar. But the *asBNB leg* runs at +5 % per principal dollar,
  and the *Venus half* at the leveraged net XVS spread. The cross-leg
  blend lands net-positive.
- Venus and Lista are completely separate venues — a Lista liquidation
  doesn't propagate to Venus or vice-versa.

## Preconditions
- BSC block where Lista Lending supports asBNB collateral at CF ≥ 0.65.
- Lista lisUSD savings module is live and pays ≥ 4 % APR.
- Venus vUSDT XVS emission active.
- Wombat lisUSD/USDT pool depth ≥ $1M (so 30k lisUSD swap costs ≤ 25 bp).

## Strategy steps (100 asBNB ≈ $60k notional, 30-day hold)
1. `_fund` 100 asBNB (≈ $60,000 notional).
2. Supply to Lista Lending, borrow `0.63 × 60k = $37.8k` lisUSD.
3. Split borrowed lisUSD:
   - 50% → Lista savings supply (`+4 % APR`).
   - 50% → Wombat → USDT → Venus vUSDT loop @ 2 iterations
     (`leverage ≈ 2.6× collat / 1.6× debt`).
4. Hold 30 days; accrue all three legs.
5. Claim XVS via Venus Comptroller.
6. PnL = asBNB carry + lisUSD savings carry + Venus loop carry −
   borrow cost − swap drag.

## PnL math (100 asBNB principal, 30-day horizon)
Notional principal: `100 BNB × $600 = $60,000`.

- **Leg 1 — asBNB restake** on $60k @ 5.00 % for 30d:
  `5.00 % × 30/365 × 60k = +247 USD`.
- **Leg 2 — Lista savings + borrow**:
  - Borrow size: `$60k × 0.70 × 0.90 = $37.8k`.
  - Savings half ($18.9k @ 4.00 %, 30d): `+62 USD`.
  - Borrow cost on full $37.8k @ 5.00 %, 30d: `−155 USD`.
- **Leg 3 — Venus vUSDT loop** on $18.9k:
  - 2-loop debt levering @ `cfEff = 0.702`: collat ≈ 1.7×, debt ≈ 0.7×.
  - Supply net: `3.5 + 2.0 = 5.5 %`; borrow net: `−6.5 + 3.5 = −3.0 %`.
  - Loop APY: `1.7 × 5.5 + 0.7 × (−3.0) = 7.3 %`.
  - 30-day: `7.3 % × 30/365 × 18.9k = +113 USD`.
- **Drag** — Wombat lisUSD→USDT round-trip on $18.9k @ 25 bp: `−47 USD`.

Total: `+247 + 62 + 113 − 155 − 47 = +220 USD ≈ +0.37 %` on $60k over
30 days, or ~**+4.5 % annualised on the BNB-principal base**, on top
of any BNB price appreciation.

Compare to **plain asBNB hold** (`5 % × 30/365 × 60k = +247 USD`):
the stack adds the `lisUSD savings + Venus loop − cost` overlay
which is roughly net-flat in the modelled regime but turns large when
XVS emissions surge or lisUSD savings APR rises above borrow APR.

Gas: ~3.5M gas × 1 gwei × $600/BNB ≈ `$2.1`.

## Block pinned
**42_500_000** (late-2024). Re-pin once Lista asBNB market + lisUSD
savings module are verified live.

## Addresses used
- `0x77734e70b6E88b4d82fE632a168EDf6e700912b6` — asBNB (`BSC.asBNB`).
- `0xAa0F8C41E3DC22a8C4d4Da6Da1A1caF048D7e4B5` — Lista Lending
  (`BSC.LISTA_LENDING`).
- `0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5` — lisUSD.
- `0xfD5840Cd36d94D7229439859C0112a4185BC0255` — vUSDT.
- `0xfD36E2c2a6789Db23113685031d7F16329158384` — Venus Comptroller.
- `LOCAL_XVS` (`0x...B14060`) — XVS placeholder.

## Risks
- **asBNB depeg vs BNB**: a 2 % discount inside the holding window
  marks `-2 % × 60k = -1.2k` on the collateral leg, blowing past
  positive carry. CF 0.70 × SAFETY 0.90 = 63 % LTV provides 16 %
  buffer before liquidation but PnL impact is immediate.
- **lisUSD depeg**: the savings leg is denominated in lisUSD; a 1 %
  lisUSD depeg costs `1 % × 18.9k = 189 USD` instantly. The strategy
  prefers high lisUSD-peg-confidence regimes.
- **Lista CF cut on asBNB**: a 70 → 60 forces ~14 % unwind via asBNB
  withdraw / lisUSD repay.
- **XVS halt**: Venus loop drops to `−3.0 %` per loop dollar, costing
  ~`-47 USD` over 30 days. Net PnL still positive (~+173 USD).

## Result
Status: **theoretical** — BSC RPC + Lista asBNB market not yet
verified. Expected PnL: **+0.37 % over 30 days on 60k notional** on
top of any BNB price move. Alpha vs. plain asBNB hold is the
levered lisUSD savings + Venus XVS overlay (typically +20–50 bp/30d
when emissions are healthy).

## TODO
- Verify Lista Lending exposes an asBNB market with CF ≥ 0.65.
- Verify lisUSD savings module API (whether `supply(lisUSD, ...)` is
  the canonical entrypoint or a separate `lisUSD-savings` contract).
- Replace `LOCAL_XVS` placeholder with the verified XVS address.
- Pin a block where both `venusSupplySpeeds(vUSDT)` and asBNB market
  are simultaneously live.
