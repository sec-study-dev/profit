# F04-01: DssFlash + PSM + Curve 3pool USDC depeg arbitrage (atomic)

## Mechanism

Three Maker/Sky primitives are stacked into one atomic transaction:

1. **DssFlash (`0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA`)** — ERC-3156 DAI flash
   mint. Maker governance currently keeps `toll = 0` (zero fee) and the
   ceiling parameter `max` at ~500 M DAI, so any address can mint up to half a
   billion DAI for one block at zero cost. No other stablecoin issuer offers
   atomic, fee-free flash mints at this scale.
2. **DssLitePsm (USDC)** — the post-Spark Lite PSM (`MCD_LITE_PSM_USDC_A` at
   `0xf6e72Db5454dd049d0788e411b06CfAF16853042`, with the legacy USDC PSM at
   `DSS_PSM_USDC = 0x89B78CfA322F6C5dE0aBcEecab66Aee45393cC5A` kept as fall-back
   route). PSMs are 0-fee in both directions (`tin = tout = 0`). `sellGem`
   converts USDC -> DAI 1:1; `buyGem` does DAI -> USDC 1:1. The PSM is the only
   protocol-level mint/burn between USDC and DAI: every 1 USDC of fee-free PSM
   capacity is a hard arbitrage anchor for the DAI peg.
3. **Curve 3pool (`0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7`)** — the
   DAI/USDC/USDT stableswap. When 3pool tilts (e.g. a USDT crisis dumps USDT
   into the pool, or a sell-off briefly pushes USDC > DAI/USDT), `get_dy(DAI ->
   USDC) > 1` or `get_dy(USDC -> DAI) > 1` for non-trivial size. The depeg
   arbitrage uses 3pool as the *price-discovery* leg and the PSM as the
   *risk-free settle* leg.

PSM `gemJoin()` is the USDC vault that holds the gem — `sellGem(usr, gemAmt)`
pulls 6-decimal USDC from the caller and mints 18-decimal DAI (`gemAmt * 1e12`)
to `usr`. `buyGem(usr, gemAmt)` does the reverse, burning DAI and releasing
USDC.

DSR rate context (block 19_500_000 era): `pot.dsr() ≈ 1.000000003022266000000000000` per
second (RAY), `pot.chi() ≈ 1.0986e27`. Not used in this PoC, but the same
DssFlash primitive underwrites every other F04 strategy.

## Why it composes

This is the canonical "Maker as the central bank" trade. No other stack offers:

- A zero-fee, half-billion-dollar one-block DAI line of credit (DssFlash) **and**
- A zero-fee, atomic, peg-anchoring USDC <-> DAI swap (PSM) **and**
- A deep stable AMM (Curve 3pool) where the same DAI sits.

When 3pool depegs (USDC trades above DAI, or vice versa), an arber with $0
collateral can: borrow DAI from DssFlash -> burn DAI for USDC at PSM (or sell
DAI for USDC into 3pool, whichever direction the depeg favors) -> close the
trade on the opposite venue -> repay DssFlash. The PnL is pure spread × notional
minus gas, with no inventory risk: the only state change at the end of the call
is `address(this).balance(DAI) += profit`.

Note that **DssFlash never charges a fee in the current parameter set** — the
loan is literally free DAI for one transaction. The only cost is gas.

## Preconditions

- Mainnet fork at a block where Curve 3pool exhibits a > 5 bp depeg in one
  direction at meaningful size (we use the USDC depeg on **2023-03-11** during
  the SVB weekend; on mainnet block **16_818_900** USDC traded ~9% below par in
  3pool and even hours later residual spreads persisted).
- `DSS_FLASH.toll() == 0` and `DSS_FLASH.max() >= 100_000_000e18`.
- `DSS_PSM_USDC.tin() == DSS_PSM_USDC.tout() == 0`.

## Strategy steps

1. Pin fork to block `16_818_900` (2023-03-11, ~12h after USDC.e regained
   parity but Curve still imbalanced).
2. Compute `get_dy_curve_dai_to_usdc` for 5_000_000 DAI. If
   `get_dy / 1e6 > (notional / 1e18) * 1.001` (>10 bp net of expected gas),
   proceed.
3. `DSS_FLASH.flashLoan(this, DAI, notional, "")` — receive DAI.
4. In `onFlashLoan`: `curve3pool.exchange(0, 1, notional, minOut)` swap DAI ->
   USDC at the depegged price.
5. `psm.sellGem(this, usdcOut)` — convert USDC -> DAI at 1:1 (zero fee, zero
   slippage).
6. Repay DssFlash: approve `notional + fee` to the flash module and return
   `ERC3156_CALLBACK_RETURN`.
7. Pocket the DAI residual.

If the depeg is in the opposite direction (DAI < USDC in 3pool), the legs swap:
`buyGem` USDC out of PSM first, then sell USDC into 3pool for more DAI.

## PnL math

For a 3pool DAI -> USDC depeg where 1 DAI fetches `1 + s` USDC:

```
profit_DAI = notional * s - flash_fee - gas_cost
           = notional * s          (flash_fee = 0 in current params)
           - gas_used * gas_price
```

A 5 M DAI notional at a 30 bp depeg yields ~$15_000 gross. Gas for the
3-call path (flash -> curve exchange -> psm sellGem -> repay) is ~450 k -> at
20 gwei and ETH=$2_400 that's ~$22 of gas. Net ~$14_978.

Size is bounded by *(a)* 3pool's price-impact curve — beyond ~$10 M the marginal
spread collapses — and *(b)* `DSS_FLASH.max()` (500 M today).

## Block pinned

`16_818_900` — Saturday 2023-03-11 14:00 UTC, mid-SVB weekend. USDC had bottomed
hours earlier and was clawing back, but 3pool's DAI/USDC ratio still showed
significant residual depeg; even by the next block range the implied edge for
1-5 M DAI was multiple bps.

If running against a fresher block where 3pool sits at parity, the PoC
auto-detects "no edge" and exits with a `no_arb` log instead of asserting a
profit. This is intentional so the test stays runnable on any block.

## Risks

- **Re-peg before mining.** Mempool searchers will close the same trade. PoC
  assumes private inclusion via builder relay.
- **PSM gem buffer.** If the PSM has no USDC (gem buffer drained because DAI
  recently bought all USDC out of it) the `buyGem` direction reverts. The
  forward `sellGem` direction is bounded by the line / vault debt ceiling.
- **DssFlash governance.** Maker can re-introduce a non-zero `toll` at any
  spell. The PoC sanity-checks `toll() == 0` at the top of the test.
- **Slippage on Curve.** Larger sizes shrink the spread; we cap notional at the
  point where the post-trade 3pool ratio is still in the money.

## Result
Status: theoretical-historical-replay
Expected PnL: +5-30 bps × notional on 1-5M DAI per event (~$15,000 gross on 5M DAI at 30 bp depeg, ~$14,978 net of gas)

Atomic, capital-free arb that monetizes any > ~5 bp DAI/USDC 3pool depeg using
Maker primitives only. PnL = depeg_spread × notional − gas. On the pinned
SVB-weekend block, the PoC asserts a strictly positive profit on a 1 M DAI
notional probe (sized small to remain in the money against searcher
competition).
