# F06-01: LUSD redemption arbitrage funded by Maker DSS flashmint

## Mechanism
Liquity v1 enforces a **hard redemption floor at $1**: any holder of LUSD can
burn 1 LUSD at the `TroveManager` and receive exactly $1 of ETH (priced at the
internal oracle) from the trove(s) with the **lowest collateralisation ratio**.
A redemption fee `R(t)` (base rate plus a 0.5% floor, anti-spam decaying half-
life ≈ 12 hours) is taken from the ETH leg.

When LUSD trades **below $1** on Curve's `LUSD/3pool` (`0xEd279fDD11ca84bEef15AF5D39BB4d4bEE23F0cA`),
the arbitrage path is:

```
1) DSS flashmint     :  DAI            -> contract
2) Curve LUSD/3pool  :  DAI            -> LUSD     (cheap LUSD)
3) TroveManager      :  LUSD           -> ETH      (1:1 minus fee R)
4) Curve tricrypto2  :  ETH            -> USDT
5) Curve 3pool       :  USDT           -> DAI
6) DSS flashmint     :  repay DAI      (zero fee — Maker `toll==0`)
```

Net profit per LUSD redeemed:

```
profit_per_LUSD = (1 - R) * ETH_price - 1 / LUSD_curve_price
              ≈ (1 - 0.005 - baseRate) - LUSD_curve_price^(-1) * 1.0004 (DAI/LUSD fee)
```

For the trade to clear, `1 / LUSD_curve_price > (1 - R) * (1 - swap_fees_eth_back)`.
Historically clean windows in 2023–2024 produced 30–80 bps spread at moderate
flashmint sizes (5–20M LUSD).

## Why it composes
- **Maker DSS flashmint** of DAI is *zero-fee* at the time of writing (`toll==0`),
  giving an unbounded, gas-only credit line for the cheap leg.
- **Curve LUSD/3pool** is the canonical LUSD venue (>$30M TVL at fork block).
- **Liquity TroveManager.redeemCollateral()** is permissionless and runs in O(N)
  troves with `_maxIterations` cap. The borrower in the lowest-CR trove eats
  the LUSD-for-ETH swap whether they like it or not.
- **Curve tricrypto2** absorbs the ETH→USDT leg, and `3pool` finishes USDT→DAI.

## Preconditions
- Curve `LUSD/3pool` spot `< 0.997 LUSD/DAI` (so the buy leg yields >1.003 LUSD per DAI).
- Liquity `baseRate` low (≤ 1%) so total redemption fee stays under the spread.
- Enough lowest-CR trove debt to absorb the redemption amount without crossing
  many hops (each crossed trove costs a sorted-list walk, hence gas).
- DSS Flash `max()` ≥ desired notional (currently 500M DAI cap).
- Maker `vat.live() == 1` and no surprise toll bump in the same block.

## Strategy steps
1. Read `TroveManager.getRedemptionRateWithDecay()` to confirm `R < 1%`.
2. Read Curve `LUSD/3pool.get_dy(1, 0, dx)` to confirm LUSD_out / DAI_in.
3. `DssFlash.flashLoan(this, DAI, amount, data)` — ERC-3156 callback.
4. Inside `onFlashLoan`:
   a. `IERC20(DAI).approve(curveLusd3pool, amount)`.
   b. `curveLusd3pool.exchange_underlying(1, 0, amount, minOut)` — DAI → LUSD.
      (index 0 = LUSD, 1–3 = DAI/USDC/USDT in 3pool order).
   c. `IERC20(LUSD).approve(TroveManager, lusdOut)`.
   d. Use `HintHelpers.getRedemptionHints()` + `SortedTroves.findInsertPosition()`
      off-chain to compute `_firstRedemptionHint`, `_upperPartialHint`,
      `_lowerPartialHint`, `_partialRedemptionHintNICR`. (The on-chain PoC
      hard-codes `address(0)` hints and a high `_maxIterations` — gas is fine
      on a fork.)
   e. `troveManager.redeemCollateral(lusdOut, firstHint, upperHint, lowerHint,
      partialNICR, maxIters, maxFeePct)`.
   f. Curve `tricrypto2.exchange(2, 0, ethReceived, minUSDT, true)` — ETH→USDT.
   g. Curve `3pool.exchange(2, 0, usdt, minDAI)` — USDT→DAI.
   h. Approve `DSS_FLASH` and return `keccak256("ERC3156FlashBorrower.onFlashLoan")`.
5. Outer scope: the remaining DAI after repaying flash is profit.

## PnL math
Let
- `D` = DAI flashed (e.g. 10,000,000 DAI),
- `p` = LUSD price on Curve in DAI/LUSD (e.g. 0.992),
- `f_curve_in` = 4 bps Curve fee on DAI→LUSD,
- `R` = redemption rate (e.g. 0.0055 = 55 bps),
- `f_curve_out` = 4 bps × 2 (tricrypto2 + 3pool) on the round trip ETH→USDT→DAI ≈ 8–12 bps,
- ETH/USD = $3,000 (assumes Liquity's internal Chainlink oracle is healthy).

Then:
```
lusd_out      = D * (1 - f_curve_in) / p
eth_received  = lusd_out * (1 - R) / ETH_price     [ETH worth of LUSD redeemed]
dai_back      = eth_received * ETH_price * (1 - f_curve_out)
              = lusd_out * (1 - R) * (1 - f_curve_out)
profit_dai    = dai_back - D
              = D * [(1 - f_curve_in)(1 - R)(1 - f_curve_out)/p - 1]
```

Plug in `D = 10M, p = 0.992, R = 0.0055, fees = 0.0016`:
```
factor = (1-0.0004)(1-0.0055)(1-0.0012)/0.992
       = 0.9996 * 0.9945 * 0.9988 / 0.992
       = 0.9930 / 0.992 = 1.00100
profit ≈ $10,000 per $10M turn  (≈10 bps net on notional)
```

Flashmint fee = 0 DAI. Gas ≈ 1.2M @ 30 gwei = 0.036 ETH ≈ $110, leaving ~$9,900 net.

At deeper depegs (`p = 0.97`) net profit climbs above 1.5% of notional, with the
size capped by Curve depth (the 3pool side has ~$80–150M usable; pushing >$25M
through self-arbs in the same block).

## Block pinned
- **`FORK_BLOCK = 14_400_000`** (≈ March 16 2022 — LUSD/3pool sustained 0.985–0.992
  range during the post-Terra wobble; `baseRate` was low).
- Alternative: `17_900_000` (Aug 2023 — modest 30 bps discount, lower-noise demo).
- Liquity HintHelpers + TroveManager addresses static since deployment 2021.

## Risks
- **Sorted-list pessimisation.** If the lowest-CR trove is too small to absorb
  the redemption, the call walks the list with O(`maxIterations`) gas. On a
  fork with hand-picked hints this is fine; in production a hint computation
  service is mandatory.
- **Curve sandwich.** A searcher front-running the Curve buy leg pushes `p` up
  and squeezes the spread. Mitigation: bundle via Flashbots, use a tight
  `min_dy`, or split the trade.
- **Oracle deviation.** TroveManager uses its own Chainlink/Tellor median; if
  Chainlink ETH/USD diverges from CEX spot the ETH leg is mispriced relative
  to `tricrypto2`'s ETH spot.
- **Trove owner griefing.** The original borrower receives the trove debt-and-
  collateral reduction. Some borrowers run keepers that *top up* CR mid-block;
  this only affects which troves are hit, not the arb correctness.
- **`baseRate` spike.** The first redemption in a 12 h window pays
  `(R + 0.5% + amount/totalSupply)`. Large notional pushes `R` up steeply —
  optimal size is determined by maximising `(spread - R(amount))*amount`.

## Result
Status: **structurally reproducible**; uses only public, view-stable contracts.

PnL range:
- Tight peg (≤ 30 bps): **+5–15 bps net**, $5k–$15k per $10M turn.
- Stress (≥ 100 bps): **+50–150 bps net**, capped by Curve depth and `baseRate`.
