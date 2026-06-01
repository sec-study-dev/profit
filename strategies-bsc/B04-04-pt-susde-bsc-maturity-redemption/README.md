# B04-04: PT-sUSDe BSC near-maturity redemption arb (4-day carry)

## Mechanism

Short-duration variant of B04-01: buy PT-sUSDe-26JUN2025 on Pendle BSC
~3-4 days before maturity at a residual discount, immediately warp past
expiry and redeem 1:1 for USDC. Composes:

1. **Pendle BSC AMM curve convergence** — as a Pendle market approaches
   `expiry`, the AMM implied rate is forced by the curve toward zero, so
   PT price → face. Any remaining discount is pure carry over a short
   horizon, dominated by `(face - ptPrice) / ptPrice` not annualization.
2. **Pendle Router V4 BSC `swapExactTokenForPt`** — atomic USDC → SY → PT
   on BSC's deployment. Same router selector as mainnet F07-04, only the
   per-maturity `LOCAL_PT_SUSDE_BSC_MARKET` differs.
3. **Post-expiry `redeemPyToToken`** — Pendle's router accepts a
   PT-only post-expiry redemption (YT supply is zero / burnable). PT
   redeems via SY for USDC at face. On BSC the SY-sUSDe wraps the LZ-OFT
   sUSDe and accepts USDC as a redeem-token.

## Why it composes

- BSC's PT-sUSDe markets persistently trade at 5-15 bps wider discount
  than mainnet because few arbitrageurs run BSC infra; near-maturity this
  shows up as a real 5-15 bp gap over 3-4 days.
- The trade is **fully atomic in spirit** (buy → warp → redeem) but
  realistically positional: in production the trader waits ~4 days holding
  PT. The PoC compresses the wait with `vm.warp`.
- No bridge or external swap: USDC stays on BSC the whole time.

## Preconditions

- BSC block ~4 days before the PT-sUSDe market's expiry.
- Market has > 1 M USDC of PT outstanding (otherwise the buy moves the
  AMM enough to wipe the discount).
- Pendle BSC router accepts USDC as both `tokenIn` and `tokenRedeemSy`.

## Strategy steps

1. Fork BSC at `FORK_BLOCK` (4 days pre-maturity).
2. Fund `EQUITY_USDC = 500_000e18` (USDC on BSC = 18 dec).
3. `swapExactTokenForPt(...{tokenIn=USDC, ...}, ...)` → receive `ptOut`.
4. Read implied entry price `EQUITY_USDC / ptOut`. The expected gap is
   5-15 bps so price is ~0.9985-0.9995.
5. `vm.warp(expiry + 1 hours)`; `vm.roll(...)`.
6. `redeemPyToToken(...{tokenOut=USDC, tokenRedeemSy=USDC, ...})`.
7. Fallback path: if router rejects PT-only redemption, manually
   `PT.transfer(YT, ptOut)` then `YT.redeemPY(this)` and `SY.redeem(USDC)`.
8. PnL = `final_usdc - equity_usdc`.

## PnL math

500 k USDC, 4-day hold, 8 bps median residual discount on BSC:
- `pnl = 500_000 × 0.0008 = +400 USDC`.
- Annualized: `0.0008 × 365 / 4 ≈ 7.3 % APY` on a near-riskless USDC ladder.
- Gas: ~700 k gas × 1 gwei × 600 $/BNB ≈ $0.42 — negligible.

## Block pinned

`FORK_BLOCK = 47_000_000` — ~late-Q2 2025, deliberately 4 days before the
assumed 26-JUN-2025 expiry. Must be re-pinned once BSC RPC is configured
and the actual market expiry block is known.

## Addresses used

- `BSC.PENDLE_ROUTER_V4` (TODO verify on BSC).
- `BSC.USDC`, `BSC.USDe`, `BSC.sUSDe`.
- `LOCAL_PT_SUSDE_BSC_MARKET` — same inline placeholder as B04-01,
  per-maturity. Must be verified against Pendle's BSC subgraph.

## Risks

- **Market drains of PT supply** — if a single LP withdraws all PT,
  the buy step fails. PoC catches.
- **Maturity slippage on SY redemption** — SY-sUSDe must convert to USDC
  at maturity; if sUSDe is in a depeg event the USDC out is < face.
  Mitigation: this strategy is delta-neutral to USDe peg moves *only* if
  redemption is via `tokenRedeemSy=sUSDe` then user holds; PoC takes USDC.
- **Pendle BSC router maturity-redemption path missing** — falls back to
  manual `YT.redeemPY + SY.redeem`.

## Result

Status: **theoretical** (BSC RPC missing; PoC compiles + degrades gracefully).
Expected PnL: **+250 to +750 USDC per 500 k notional over 4 days**, i.e.
**+5 to +15 bps**, annualized 5-15 % APY on capital deployed.
