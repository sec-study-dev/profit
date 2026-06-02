# B15-04 — Astherus asBNB · Venus collateral · Pendle YT points stack

## Family

B15 · 三协议机制堆叠. BSC analogue of F18-05's "tri-restake" pattern but
expressed on BSC's points layer: asBNB restake + Venus collateral
amplification + Pendle YT to *isolate the points stream from the principal*.

## Thesis

asBNB on Astherus restakes BNB into a Babylon-style restaking layer (BSC's
restake-equivalent). The position simultaneously earns:

1. **asBNB restake points** (Astherus + Babylon double-stream).
2. **Venus borrow capacity** when asBNB is supplied as collateral
   (assumed; Venus has been listing LST collaterals on the Core pool).
3. **Pendle YT-asBNB** when the borrowed BNB/USDT is spent on YT — YT
   tokens entitle the holder to **all the points + yield** accruing to a
   notional 1 asBNB until maturity, for a small price (the implied YT
   price = 1 − PT price ≈ 1–8 % of notional).

The triple stack:

1. Mint `asBNB` from BNB (Astherus StakeManager).
2. Supply `asBNB` to Venus, `borrow USDT` against it at ~50 % LTV.
3. Use the borrowed USDT to mint `YT-asBNB-26JUN2025` on Pendle BSC.
   YT-asBNB exposes the buyer to **N×** the underlying asBNB's points
   accrual per dollar (because the carry is highly leveraged once
   stripped from principal).

End state:
- The user holds asBNB (earning baseline points stream),
- borrows USDT against it (paying floating rate),
- and *simultaneously* owns YT-asBNB whose points stream is roughly
  `1/(YT price)` × what plain asBNB would earn → 10–50× leverage on
  asBNB's points.

## Why it composes — the 3 mechanisms

1. **Astherus StakeManager (asBNB mint)** — only protocol on BSC that
   issues a restake-share token. The underlying restake layer (Babylon)
   accrues independent points; converting BNB at canonical rate is the
   cheapest entry.
2. **Venus Core `vAsBNB`-class collateral** — only money market with
   liquidity to absorb asBNB collateral and emit USDT for the YT-buy
   leg. Without Venus, the strategy needs seed USDT.
3. **Pendle YT-asBNB `swapExactTokenForYt`** — only protocol on BSC that
   tokenises a points stream. Without Pendle YT, the strategy is a
   plain Venus LST loop (B01/B11 class) — no points-leverage edge.

**No 2-mechanism subset achieves "leverage-amplified restake points":**
- (Astherus + Venus) — yields capacity but no points leverage (B11-01).
- (Astherus + Pendle YT) — yields points leverage but no balance-sheet
  amplification (B04-03).
- (Venus + Pendle YT) — no underlying restake leg; YT-asBNB requires
  asBNB held somewhere in the system.

The triple is unique in *concurrently* holding the principal (for
baseline points), borrowing against it (for capital efficiency), and
recycling the borrow into the **highest-multiplier** points leg (YT).

## Preconditions

- BSC block where Astherus asBNB is deployed (~Q4-2024+).
- Venus Core has an asBNB market or accepts WBETH as a substitute (fall-
  back).
- Pendle PT/YT-asBNB market live on BSC.

## Strategy steps (PoC)

1. Fund 100 BNB equity.
2. **Leg A**: `IListaStakeManager` (proxy — Astherus uses a similar
   stake interface) → mint asBNB. Offline: assume 1:1.
3. **Leg B**: Approve asBNB to vAsBNB (use `vBNB` as fallback). Mint
   vAsBNB, enter market, borrow `0.5 × $value` of USDT.
4. **Leg C**: Approve USDT to Pendle router; `swapExactTokenForYt(market
   =YT-asBNB-26JUN2025, tokenIn=USDT, ...)`. Receive ~30 000 USDT-
   worth of YT-asBNB (YT face = 1 asBNB, market price ≈ $30 ↔ $600
   asBNB = 5 % YT-price → 20× leverage).
5. Hold ~90 days; YT accrues points + interim yield. Realised PnL is
   points-denominated and off-chain at airdrop.

## PnL math (points class)

100 BNB ≈ $60 000 equity. After:
- asBNB held: 100 (baseline points stream).
- vAsBNB-collateralised, USDT borrowed: 30 000.
- YT-asBNB acquired: 30 000 / 0.05 = **600 YT face** (each entitled to
  1 asBNB's yield to maturity).

Points multiplier over 90-day window:
- Baseline (100 asBNB held): 100 × 90 = 9 000 asBNB-points-days.
- Through YT-leg: 600 × 90 × points-coupon-fraction ≈ 600 × 90 × 0.10 =
  **5 400 asBNB-points-days** (YT only captures the *coupon*, not the
  full yield, so this is conservative).

Total ≈ **14 400 asBNB-points-days** vs. 9 000 baseline = **1.6× points
leverage** on equity.

Cash leg (modelled):
- Venus borrow cost on 30 000 USDT @ 5 %: 30 000 × 0.05 × 90/365 = **−$370**
- YT decay to zero at maturity: −30 000 USDT (sunk cost; covered if
  realised points value > $370 + $30 000).

Break-even per-point value: 30 370 / 5 400 = **$5.62 / asBNB-point-day**.
If asBNB points sell for > $5.62/day-of-stake equivalent at airdrop, the
strategy is profitable. Recent BSC restake airdrops (Lista, Astherus) have
indicated this is in the bid range for a top-of-book program.

## Block pinned

`FORK_BLOCK = 42_800_000`. Re-pin once Pendle YT-asBNB market is verified.

## Addresses used

- `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.asBNB`.
- `BSC.VENUS_COMPTROLLER`, `BSC.vBNB` (proxy for vAsBNB fallback),
  `BSC.vUSDT`, `BSC.USDT`.
- `BSC.PENDLE_ROUTER_V4`, `LOCAL_YT_ASBNB_MARKET` — inline placeholder.

## Risks

- **YT decay**: YT loses its entire value at maturity if no points
  airdrop materialises. This is *the* primary risk.
- **Venus has no asBNB market**: PoC `try/catch`s; falls back to vBNB
  collateral (loses ~25 % of the carry's points-amplification).
- **Pendle YT thin liquidity**: large YT buy can move PT price materially;
  PoC caps at 30 k USDT equivalent.

## Result

Status: **offline-draft / points-class alpha**. Cash PnL at fork block:
≈ −$30 000 (YT premium paid up-front, minus interest). Realised PnL is
points-denominated at airdrop with very high uncertainty: typical
restake-points programs on BSC have paid out $0.02–$0.40 per
points-unit, giving a payout range of **+$300 to +$5 800 on $60 k
equity**.

## TODO

- Confirm `IAstherusStakeManager` actual ABI (current placeholder reuses
  `IListaStakeManager.deposit{value}()`).
- Confirm Venus has a vAsBNB listing or pick the cleanest fallback.
- Verify the Pendle YT-asBNB market address + expiry.
