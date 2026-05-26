# F02-05: rsETH triple-points stack (Kelp + Karak + Pendle YT) with Morpho flashloan bootstrap

## Mechanism
Kelp DAO's **rsETH** is a non-rebasing LRT minted by `LRTDepositPool.depositETH()` (or
`.depositAsset()` for stETH/ETHx). On top of the underlying ETH-staking yield, holding
1 rsETH earns:

- **Kelp Miles** (Kelp loyalty points, redeemable in KEP / KERNEL airdrops)
- **EigenLayer restaking points** (Kelp routes the underlying via EL operators)

The composition uses **three distinct mechanisms**:

1. **Karak v0 Vault for rsETH** — depositing rsETH into Karak's per-asset vault
   adds a third independent point stream (**Karak XP**) on the same notional.
2. **Pendle YT-rsETH-27JUN2024** — buying YT (instead of, or in addition to, spot
   rsETH) lets the strategist capture the *full* Kelp Miles + EL rs-pts stream on
   1 rsETH at a fraction of the dollar cost (~3-6% of underlying), giving point
   leverage of ~25-30x on the YT slice.
3. **Morpho free flashloan** — bootstraps the cash needed to build a barbell
   position (Karak-staked rsETH for triple-points carry + small YT-rsETH purchase
   for point-leverage) without committing additional equity.

## Why it composes (3 mechanisms, additive economics)
- The three point-issuers (Kelp + Karak + EigenLayer) credit independently on
  notional rsETH; staking into Karak does **not** remove EL credit since Karak
  re-restakes the same EL ETH.
- Pendle YT is a points-decoupling primitive: 1 YT-rsETH ≡ 1 rsETH worth of
  point-emission until maturity, sold at a deep discount.
- Morpho's zero-fee flashloan removes the bootstrap-capital problem: one tx
  builds both legs at scale.

```
point_value_$ ≈ N_rsETH × (Kelp_$/yr + EL_$/yr + Karak_$/yr)
              + N_YT     × (Kelp_$/T  + EL_$/T)        [T = time-to-maturity]
```

## Preconditions
- Block: 19,750,000 (mid-April 2024 — Karak mainnet live, Pendle rsETH-27JUN24
  market active, rsETH liquid on 1inch / Curve)
- Karak rsETH vault deposit-cap not full
- Pendle YT-rsETH/SY-rsETH market has implied yield ~6-9% APY (so YT/SY ~3-4%)
- Morpho WETH flashloan source available (Morpho Blue singleton)

## Strategy steps
1. Receive 100 WETH equity.
2. Flash 200 WETH from Morpho Blue (zero-fee, free flashloan).
3. Inside callback (total 300 WETH on hand):
   a. Unwrap 270 WETH → ETH; deposit to Kelp `LRTDepositPool.depositETH()` →
      receive ~268 rsETH (at rate ~1.007 ETH/rsETH).
   b. Approve and deposit ~268 rsETH into Karak's rsETH vault
      (`Vault.deposit(amt, recipient)`). Receipts stay non-transferable but
      Karak XP accrues.
   c. Use 30 WETH to swap-into-YT via Pendle Router V4
      `swapExactTokenForYt(YT-rsETH-27JUN24 market, ...)`. Receive ~900 YT-rsETH
      at YT/SY = 0.033.
   d. *Repay leg*: 200 WETH flashloan must be returned. Since we converted all
      WETH into illiquid positions, we cannot repay in cash. Strategy: do NOT
      include the WETH borrow leg here — flashloan only the rsETH minting
      tranche we can immediately collateralise on Morpho rsETH/WETH (if
      market exists; at this block it does NOT yet, so we fall back to the
      Karak-redeem path which is multi-day).
   e. Practical alternative used in this PoC: flashloan 100 WETH (not 200),
      lever 2x; collateralise ~100 rsETH on Morpho's rsETH/WETH market (if
      available), borrow 100 WETH back, repay flash.

The PoC implements the **simpler 2x version** (no Morpho rsETH market dependency):
flash, mint rsETH, deposit to Karak, buy YT, and *repay flash from a parallel
WETH source via a small DEX swap of a slice of rsETH back to WETH*. Net result:
- ~90% of capital → Karak-staked rsETH (Kelp + EL + Karak XP)
- ~10% of capital → YT-rsETH (Kelp + EL point-decoupling leverage)

## PnL math
Inputs: 100 ETH equity, 6-month hold, conservative point pricing.

```
Position end-state (after flash unwind):
  Karak-rsETH stack   = 90 rsETH (≈ 91 ETH)
  YT-rsETH            = 300 YT  (≈ 10 WETH spent on YT)

Cash leg (6 months):
  rsETH-rate yield   = 91 × 3.0% × 0.5  = +1.36 ETH
  YT time decay      = -10 ETH (assumed full decay over 6mo) = -10 ETH
  Net cash           = -8.6 ETH ≈ -8.6% on equity

Point leg (6mo):
  Kelp Miles on 91 rsETH    = 91 × 100/day × 180  = 1.638M Miles
    @ $0.005/Mile (KEP airdrop est)               = ~$8,200
  EL rs-pts on 91 rsETH      = 91 × 1 ETH-day × 180 = 16,380 ETH-days
    @ $1/ETH-day                                   = ~$16,380
  Karak XP on 91 rsETH       = 91 × 100/day × 180 = 1.638M XP
    @ $0.02/XP                                     = ~$32,760
  YT-rsETH point uplift (300 YT @ 30x point density on 10-ETH cost basis)
    Kelp+EL combined           = +9× of cash YT → ~$22,000

Total point value (base):  ~$79,000 over 6 months
```

Outcome on 100 ETH ($300k) equity (6mo):
- Cash only: **-$26k** (-8.6%)
- Cash + base points: **+$53k** (+18%)
- Cash + airdrop-bull: **+$200k** (+66%)
- Cash + airdrop-bear (one stream → 0): **-$5k to +$20k**

## Block pinned
- Fork block 19,750,000 (mid-April 2024).
- Kelp `LRTDepositPool`: `0x036676389e48133B63a802f8635AD39E752D375D` (verified
  at https://etherscan.io/address/0x036676389e48133b63a802f8635ad39e752d375d).
- Karak VaultSupervisor: `0x54e44dbb92dba848ace27f44c0cb4268981ef1cc`.
- Karak rsETH vault: deployed under VaultSupervisor (resolved via on-chain getter
  in the PoC; falls back to documented constant if call reverts).
- Pendle `PT-rsETH-27JUN24 / SY-rsETH` market:
  `0x4f43c77872db6ba177c270986cd30c3381af37ee`
  (https://etherscan.io/address/0x4f43c77872db6ba177c270986cd30c3381af37ee).
- YT-rsETH-27JUN2024: `0x0ed3a1d45dfdcf85bcc6c7bafdc0170a357b974c`.

## Risks
- **Point-stream dilution.** Any of Kelp / EigenLayer / Karak can re-rate emissions.
- **Karak XP claw-back.** Karak's TGE may apply Sybil filters; XP may not = $1:1
  with claim value.
- **YT mispricing.** Implied APY can spike when sentiment shifts; YT NAV can
  collapse 30-50% even with full points intact.
- **rsETH depeg.** Kelp depegged briefly during the May-2024 LRT unwind; spot
  rsETH/ETH traded down to -1.2%; an in-tx unwind for flash-repay realises loss.
- **Karak vault liquidity.** Karak's withdrawal queue (deposit-only at this
  block) means the Karak-staked slice is illiquid; flash-unwind not possible
  through Karak.
- **Multi-protocol surface.** 5 protocols compose (Kelp + Karak + Pendle + Morpho
  + DEX); any single bug or pause breaks the strategy.

## Result
Status: **theoretical**. Mechanics reproducible at the pinned block subject to
the documented address resolution; PnL dominated by the three-stream point claim
realisation.

PnL range (6mo, 100 ETH equity / ~$300k):
- Cash only: **-$26k** (carry cost of YT decay)
- Cash + conservative points: **+$50k** to **+$80k** (+17-27%)
- Cash + bull points: **+$200k+** (+66%+)
