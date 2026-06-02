# B13-08: Pendle PT-sUSDe cross-chain (ETH vs BSC) bridge spread

## Family
B13 — Cross-chain bridge LST/stable discount arbs.

## Thesis
Pendle's PT-sUSDe markets exist on both Ethereum and BSC. The fixed-yield
APY on the same maturity differs because the two markets have different
liquidity depth and YT demand: when BSC PT yields are *higher* than ETH,
PT-sUSDe-BSC trades cheaper per implied USD-at-maturity than PT-sUSDe-ETH.
Recurring 1-3 % APY gaps on a 30-90 day maturity translate to **40-90 bp
of notional**.

The bridge primitive is **Ethena's sUSDe / USDe OFT** (LayerZero V2),
which carries the *underlying* stable cross-chain at par. The PT itself
isn't directly bridged; we lock the spread by buying PT on the cheap side
(BSC) and bridging the underlying to the dear side, where it's redeemed
or held against the higher-yielding PT.

## Bridge primitive
- **Ethena USDe / sUSDe OFT adapter** (LayerZero V2 `send`).
- **PCS v3 single-pool flash** for the cheap USDT loan.
- **Pendle V4 Router** `swapExactTokenForPt` (PT market on BSC).
- **PCS v3 USDe/USDT pool** as the third venue for residual cleanup.

## Mechanism count: **3-mechanism**
1. PCS v3 USDT flash (cheap loan).
2. Pendle V4 `swapExactTokenForPt` on BSC PT-sUSDe market.
3. Ethena OFT `send` to bridge the (redeemed) underlying sUSDe to ETH.
4. PCS v3 USDe/USDT swap on residuals (third venue).

## Atomic vs positional
**Positional.** The PT purchase + OFT burn are atomic within the flash
callback. The ETH-side fill (mint of sUSDe -> sale of ETH PT or redemption
at maturity) lands minutes to days later depending on the chosen exit. PnL
is booked at flash time against the par value of the bridged sUSDe.

## Block pinned
- `FORK_BLOCK = 45_500_000` — placeholder. Re-pin to a window where the
  BSC PT-sUSDe APY exceeds ETH PT-sUSDe by > 1.5% on the same maturity.
  TODO scan Pendle analytics.

## PnL math
At 60 bp PT-spread on $200k notional:
- PT purchase yields `$201_200` of par-at-maturity sUSDe.
- ETH-side redemption / sale: 4 bp OFT tax + 10 bp ETH-side route =
  `$200_920`.
- Flash fee (1 bp): `$20`.
- LZ + Pendle gas: ~$5.
- Net: **~$900 per cycle**, scales linearly with spread and notional.

## Preconditions
- BSC Pendle deployment exposes PT-sUSDe market at non-zero address
  (TODO verify `PT_SUSDE_MARKET_BSC`, `PT_SUSDE_BSC`).
- Ethena OFT adapter on BSC is live (TODO verify `ENA_OFT_ADAPTER`).
- Adequate SY liquidity in the BSC PT-sUSDe market (> $1M).
- ETH-side PT/sUSDe path active for the exit.

## Risks
- **PT market shallow on BSC** — slippage can absorb most of the spread
  at sizes > 5% of market liquidity.
- **OFT delivery delay** > LZ confirmation window. If sUSDe arrival on
  ETH is delayed past Pendle's YT-rate snap, the implied PnL on the ETH
  side erodes.
- **sUSDe yield jump** during the bridge window changes the basis.
- **Underlying tokens (USDe) potentially mismatched** between chains —
  the PoC redeems PT-sUSDe to sUSDe and bridges sUSDe; if sUSDe OFT is
  not yet deployed, fallback is redeem to USDe and use the USDe OFT
  (B13-04's path).

## TODO
- Resolve `PT_SUSDE_MARKET_BSC`, `PT_SUSDE_BSC` addresses (verify Pendle
  BSC deployment).
- Resolve `ENA_OFT_ADAPTER` on BSC.
- Confirm Pendle Router V4 BSC deployment matches the mainnet address.
- Re-pin `FORK_BLOCK` to an APY-spread observation window.
