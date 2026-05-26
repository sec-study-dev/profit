# F17-06: OETH depeg entry → wOETH → Aave ETH-correlated e-mode loop

## Mechanism

Three primitives combine into a **persistent levered carry**:

1. **Origin Curve OETH/ETH pool** — same depeg window F17-03 exploits, but
   instead of flashing the round-trip we *hold* the discounted OETH and
   recycle it as collateral.
2. **wOETH (ERC-4626 wrapper)** — Origin's non-rebasing share over OETH.
   Required because Aave's interest-index accounting cannot safely handle
   a token with a rebasing balance — wOETH's `convertToAssets(shares)`
   grows monotonically while balances stay constant.
3. **Aave V3 ETH-correlated e-mode** (categoryId = 1) — when wOETH is
   listed inside the ETH e-mode (alongside WETH / wstETH / weETH / cbETH),
   it earns up to ~90% LTV / 93% LT against WETH borrow. The looped
   position carries:
   - OETH's vault APY (from underlying stETH/frxETH/etc.)
   - the entry-time Curve discount (bonus collateral seeded at no cost)
   - minus the Aave WETH borrow rate.

```
seed WETH  --Curve discount swap-->  OETH (>1:1)  --wOETH.deposit-->
   wOETH  --aave.supply(eMode=ETH)-->  collateral
   aave.borrow(WETH)  --Curve-->  more OETH  --wrap-->  more wOETH  --supply-->
   (loop)
```

## Why it composes

This is the **steady-state companion** to F17-03's flash-arb. The
flash-arb captures a one-shot discount; this strategy captures the
discount *and* compounds the OETH carry on top. The composition is
deliberately three-way:

- **Origin/Curve mechanic** — sets the entry price (sub-peg)
- **wOETH wrapper** — adapts the rebasing token to Aave's index-based
  accounting (the universal-rebase-to-money-market pattern)
- **Aave e-mode** — provides the levered multiplier

It is also a **diagnostic**: if Aave does *not* list wOETH at FORK_BLOCK
the strategy falls back to a redeem-via-vault exit (using F17-03's
vault redeem path) to bank only the discount; this verifies that the
e-mode-loop opportunity does or does not exist at the pinned block.

## Preconditions

- Curve OETH/ETH pool live and OETH trading at <1:1 vs ETH at FORK_BLOCK.
- wOETH wrapper live with `asset() == OETH`.
- Aave V3 has either:
  - wOETH listed in ETH e-mode (full loop), or
  - no wOETH reserve (PoC executes redeem-only path and exits)

## Strategy steps

1. Pin **block 20_400_000** (Jul 19 2024). Same window as F17-03.
2. Inspect Curve pool layout; gate execution on `dy/principal ≥ 1.004e18`
   (i.e. ≥40 bps discount in OETH's favor).
3. Inspect Aave wOETH reserve; if unlisted, fall through to redeem-only
   path.
4. Fund 50 WETH seed; unwrap to ETH; swap on Curve → OETH (capturing
   the discount in OETH units).
5. Wrap OETH → wOETH.
6. Supply wOETH to Aave; enter ETH e-mode.
7. Loop 3×: borrow WETH at LOOP_LTV_BPS = 85%; unwrap; swap WETH→OETH;
   wrap; supply. Health-factor gate at each step.
8. Report collateral / debt / HF and exit.

## PnL math

Two distinct PnL components:

**A. One-shot discount.** Entry leg captures `(dy - principal)` OETH at
the swap. For a 50 bps discount on 50 WETH: extra ~0.25 OETH worth of
collateral. Bank value ~0.25 ETH ≈ $750 (at ETH=$3000).

**B. Persistent levered APY.**

```
NetAPY = L · r_OETH − (L−1) · r_borrow
```

with L = 1 / (1 − LTV·safe_frac). At LTV=0.85, safe_frac=0.85,
L ≈ 1 / (1 − 0.7225) ≈ 3.6×. With r_OETH ≈ 4% (Origin's published Jul-24
APY) and r_borrow ≈ 2.5% (Aave V3 WETH variable APY at FORK_BLOCK):

```
NetAPY = 3.6 · 0.04 − 2.6 · 0.025
       = 0.144 − 0.065
       = 0.079 ≈ 7.9%
```

On 50 WETH equity (≈ $150k) over a year: ~$11.8k vs unlevered ~$6k.

Gas: 3 Curve swaps + 3 wrap + 4 Aave ops ≈ 1.6M ≈ $96 at 30 gwei.

## Block pinned

`20_400_000` (Jul 19 2024). OETH discount window per F17-03 documentation;
wOETH wrapper live; Aave V3 ETH e-mode operational with weETH/wstETH
already listed (wOETH listing depends on AAVE governance).

## Risks

- **wOETH not listed on Aave V3 mainnet at FORK_BLOCK.** Likely true for
  mid-2024; this is the dominant production scenario. The PoC handles
  cleanly via the redeem-only branch — banks the entry discount only.
- **Curve discount priced out.** Other arbitrageurs may have closed the
  gap. PoC's quote gate exits no-op if `ratio < 1.004e18`.
- **OETH rebase pause.** Origin governance can pause harvester calls;
  if rebase stops the carry collapses to whatever Aave WETH supply-side
  yield exists on wOETH (typically negative when borrowed).
- **eMode LT-breach.** ETH-correlated eMode has an LT of ~93% so the
  loop is safe at LOOP_LTV_BPS=85%; an OETH/ETH oracle deviation event
  (e.g. a fast Origin rebase pause + Curve pool drain) could push HF
  below 1.0. The PoC asserts `hf > 1.05e18` between iterations.
- **wOETH oracle source.** If Aave uses its own wOETH/ETH oracle, that
  oracle may diverge briefly from Curve's spot; the e-mode loop should
  not be over-aggressive on the very first cycle.

## Result
Status: theoretical-historical-replay
Expected PnL: ~7.9% APY on equity if wOETH listed (~$11.8k/yr per 50 WETH (~$150k) seed at L=3.6x, OETH APY=4%, Aave WETH borrow=2.5%); plus ~0.25 ETH (~$750) one-shot discount at 50 bp entry

A three-mechanism levered carry that integrates the F17-03 depeg
opportunity into a steady-state Aave loop, with wOETH as the connector
asset. Captures both the one-shot Curve discount and the ongoing OETH
rebase APY at ~3.6× leverage when Aave lists the wrapper; otherwise
documents the no-listing reality and banks only the discount.
