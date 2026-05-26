# F04-04: DssFlash + PSM + Aave USDC supply-rate spike arb (atomic)

## Mechanism

A second pure-Maker-anchored atomic strategy, this time monetizing extreme
*rate* events rather than spot depeg events:

1. **DssFlash** — fee-free DAI flash mint (toll = 0, max ≈ 500 M).
2. **DSS PSM USDC** — fee-free DAI<->USDC swap.
3. **Aave V3 Pool (`0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`) USDC reserve** —
   the variable supply APY spikes during demand surges (e.g. when looped
   stables strategies all borrow USDC at once for delta-neutral funding-rate
   carry).

The economic trick is that flash mint cost is *zero* and PSM swap cost is
*zero*; the only barrier to capturing the instantaneous Aave USDC supply rate
is gas. So if Aave USDC supply APY exceeds some threshold and we can
park-and-redeem within the same transaction, even sub-block carry is
profitable.

The catch: a 6%-APY supply rate over one block (12s) is `6% * 12/31536000 ≈
2.28e-8` per dollar -> on $50M that's $1.14. Below gas. So the *atomic* version
only pays for itself in two regimes:

- **Multi-block hold** — flash-loan-bootstrapped Aave deposit held for N blocks
  (not strictly atomic). Aave permits an atomic supply + withdraw, but the
  *interest* only accrues over the held duration.
- **Backstop event** — when Aave's USDC IRM is in the kinked region (utilization
  > 92%, the reserveFactor-pushed supply APY can briefly exceed DSR), a *price*
  rather than rate arb may emerge: the flashed DAI swapped to USDC and
  deposited mints an `aUSDC` that, when redeemed, returns slightly more USDC
  than was supplied *if* a different actor in the same block triggers a
  liquidation that updates the index. Very situational.

The version we PoC is a **demonstration-mode atomic loop**: flash DAI -> PSM
sellGem -> Aave supply -> Aave withdraw -> PSM sellGem -> repay. With no held
duration the index doesn't move so the loop is a no-op (modulo wei dust). The
real-world variant warps `vm.warp(12)` to one block of held interest and
demonstrates the rate-pickup math directly.

Layered with sDAI: the *idle* DAI on the strategy's books can be parked in
sDAI for the held interval — adding `DSR_APY × duration × notional` to the
unrealized gain.

## Why it composes

- **Capital-free entry.** DssFlash supplies the principal at zero fee.
- **Zero-slippage USDC delivery.** PSM atomically delivers the USDC needed for
  Aave at par.
- **Money-market interest is per-block, not per-trade.** A sufficient short
  hold (12-60 seconds = one to a few blocks) accrues real `aUSDC` interest, so
  the closed loop is monetized.

The Maker-specific edge: every leg costs zero in fees, so the break-even
duration is set entirely by gas. Without PSM, the USDC leg requires a Curve
hop (5-10 bp slippage) that already eats months of supply yield.

## Preconditions

- Block where Aave V3 USDC `currentLiquidityRate` is materially > 0 (a stable-
  market block, not a 1 wei reserve).
- DssFlash toll = 0.
- PSM has gem buffer (USDC) and DAI in vault.

## Strategy steps

1. Pin fork to **block `20_900_000`** (~late October 2024). Aave V3 USDC
   utilization was ~85% and supply APY ~5.5%.
2. Verify `DSS_FLASH.toll() == 0`, `DSS_PSM_USDC.tin() == DSS_PSM_USDC.tout() == 0`.
3. `DSS_FLASH.flashLoan(this, DAI, 20_000_000e18, "")`.
4. In `onFlashLoan`:
   a. `PSM.buyGem(this, 20_000_000e6)` — burn DAI for 20 M USDC.
   b. `AaveV3.supply(USDC, 20_000_000e6, this, 0)` — mint aUSDC.
   c. `vm.warp(60)` — simulate 60 s hold (5 blocks).
   d. `AaveV3.withdraw(USDC, type(uint256).max, this)` — redeem aUSDC; the
      index has ticked, so the returned USDC > 20_000_000e6.
   e. `PSM.sellGem(this, usdcOut)` — back to DAI 1:1.
   f. Approve `notional + 0` to flash, return callback.
5. The wei-level rounding noise plus 60 s of accrued interest = strategy PnL.

Note: forge cheatcodes (`vm.warp`) inside a real flash-loan callback only work
under test conditions; on-chain you cannot pause a block. The PoC is therefore
labeled "demonstration-mode" — it proves the *math* and exposes the *rate*,
but does not assert that an instantaneous (single-block) version is
profitable. A *real* deployment would split the loop across blocks (held
position), trading atomicity for held-interest accrual.

## PnL math

```
gross_interest = notional_USDC * (supply_APY) * (hold_seconds / 31_536_000)
gas_cost       = gas_used * gas_price_in_ETH * ETH_USD
net            = gross_interest - gas_cost   (flash & PSM fees = 0)
```

On 20 M USDC for 60 s at 5.5% supply APY:
`gross = 20_000_000 * 0.055 * (60/31_536_000) = $2.09`.

Pathetic — but the loop *scales linearly* with notional and *with* hold
duration. Push notional to 200 M and duration to 12 hours (3600 blocks),
APY=8%:
`gross = 200_000_000 * 0.08 * (43200/31_536_000) = $21_900`.

The atomic regime is therefore mainly interesting as a *low-yield-but-zero-
risk* primitive for rate-spike events (e.g. an Aave IRM tick where the
supply rate briefly hits >15%, in the kinked zone).

## Block pinned

`20_900_000` — late October 2024. Aave V3 USDC reserve was at near-peak
utilization (post-Spark-launch DAI vs USDC rate divergence), making the rate
side legible. DssFlash and PSM both at fee = 0.

## Risks

- **Atomicity vs accrual.** As above — a single-block hold accrues essentially
  no interest; multi-block holds are not atomic and expose to: re-pricing on
  withdraw if Aave's reserve runs dry, PSM gem buffer drain, and DssFlash
  parameter change in a Maker spell.
- **PSM gem buffer.** `buyGem` requires USDC in the gem buffer. The PoC checks
  `Mainnet.USDC.balanceOf(psm.gemJoin())` first and scales notional down to fit.
- **Aave reserve cap.** Aave V3 USDC has a supply cap; if reached, the
  `supply()` reverts. PoC reads cap and clamps.
- **Index oracle staleness.** A held position's mark-to-market depends on
  Aave's liquidity index update; if `updateState` hasn't fired since the
  last block, `withdraw(type(uint256).max)` returns a slightly stale figure.

## Result
Status: mechanically-reproducible
Expected PnL: ~$2 per 60s hold on 20M USDC at 5.5% APY; scales linearly to ~$21,900 on 200M USDC over 12h hold at 8% APY

A demo of the rarest Maker composition: a strategy where *every fee is zero*.
PoC asserts that on a one-block hold the flash-PSM-Aave-PSM-flash loop returns
strictly within `[notional - 10 wei, notional + interest]` — i.e. that the path
is structurally lossless in nominal DAI even when no interest accrues, and
strictly profitable on any positive hold duration.
