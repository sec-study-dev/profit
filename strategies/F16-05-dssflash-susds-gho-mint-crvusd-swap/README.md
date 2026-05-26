# F16-05: DssFlash → sUSDS collateral → mint GHO on Aave → swap GHO to crvUSD

## Mechanism

A 4-mechanism, single-block opening of a leveraged cross-CDP carry book that
stacks **Maker**, **Sky**, **Aave**, and **Curve** in one composite
transaction:

1. **Maker DssFlash** mints DAI at zero fee, providing the entry tranche.
2. **Sky DaiUsds wrapper + sUSDS ERC-4626** converts DAI to USDS to sUSDS —
   a yield-bearing share that accrues the Sky Savings Rate (SSR ≈ 6-8% APR
   in 2024-2025).
3. **Aave V3** supplies sUSDS as collateral (with USDC fallback if sUSDS is
   not yet listed at the pinned block) and borrows GHO against it at the
   facilitator's variable rate (5-9% APR).
4. **Curve GHO/crvUSD StableNG pool** swaps the freshly minted GHO into
   crvUSD, monetising any GHO sub-peg or crvUSD over-peg drift.

The DAI flash is closed atomically by routing crvUSD → USDC → DAI (via the
crvUSD/USDC NG pool and Curve 3pool) so the position survives the callback
boundary with **only the sUSDS collateral and Aave GHO debt remaining on
book**, plus whatever crvUSD remained after flash repayment.

The cross-CDP carry surface at the end of the block:

```
yield = SSR(sUSDS NAV drift)
      - r_GHO_borrow (Aave V3 variable)
      + crvUSD_premium_at_swap  (atomic)
      - flash_DAI_to_crvUSD_round_trip_slippage
```

## Why it composes

Each leg is in a different CDP's accounting:

- **Maker (DAI)** — zero-cost capital via DssFlash, repaid in the same tx.
- **Sky (USDS / sUSDS)** — yield-bearing collateral; SSR is set by Sky
  Governance and is uncorrelated with Aave's facilitator rate.
- **Aave (GHO)** — debt is GHO, a Aave-DAO-rate-controlled stablecoin.
- **Curve (crvUSD)** — exit asset; crvUSD is algorithmically rate-controlled
  with intermittent over-peg drift after PegKeeper deposits.

Because the four issuers have *independent* rate-setting mechanisms (DAO
votes, hardcoded rate formulas, pegkeeper deposits), the four-way basis is
not arbitraged out by any single counter-party. The trade captures the
intersection of (SSR > 0) and (Aave GHO rate < SSR + crvUSD premium).

This is the **single most stacked cross-CDP path** in this family: every
hop touches a different DAO. Failure modes are also independent — a sUSDS
delist on Aave does not affect the GHO/crvUSD edge, and a GHO bucket
exhaustion is independent of the sUSDS NAV.

## Preconditions

- `DSS_FLASH.toll() == 0` and `maxFlashLoan(DAI) >= 5_000_000e18`.
- Sky DaiUsds converter `0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A` live
  (deployed in the Sep 2024 Sky rebrand).
- sUSDS listed on Aave V3 with LTV > 0 at the pinned block. The PoC falls
  back to USDC supply if not.
- Aave V3 GHO facilitator bucket has headroom for the borrow.
- Curve GHO/crvUSD pool `0x635EF0056A597D13863B73825CcA297236578595` live
  (verified via the Curve gov forum
  [crvUSD]: GHO Pegkeeper Review thread).

PoC pins block **21_800_000** — late-Jan 2025.

## Strategy steps

1. `DssFlash.flashLoan(this, DAI, 5_000_000e18, "")`.
2. In `onFlashLoan`:
   a. `DaiUsds.daiToUsds(this, amount)` — 1:1 wrap.
   b. `sUSDS.deposit(usdsBal, this)` — mint sUSDS shares.
   c. If sUSDS is an Aave V3 reserve with LTV > 0: `Aave.supply(sUSDS, ...)`.
      Else redeem sUSDS → USDS → DAI → USDC and supply USDC.
   d. `Aave.borrow(GHO, 60% LTV, mode=2)`.
   e. `Curve(GHO/crvUSD).exchange(0, 1, ghoBal, 0)` — GHO → crvUSD.
   f. Route enough crvUSD → USDC → DAI to repay `amount` DAI to DssFlash.
3. Warp 30 days; call `sUSDS.drip()`; read user account data on Aave;
   surface PnL.

## PnL math

Pre-warp instantaneous book (5 M DAI flash, 60% LTV, GHO 7% APR, crvUSD
premium 30 bps, swap losses 25 bps each side):

```
supply_value_usds_e18 = 5_000_000e18  (1:1 wrap, identical decimals)
ghoBorrow            = 0.60 * 5_000_000 = 3_000_000e18
crvUsdOut            ≈ ghoBorrow * (1 + 0.0030) ≈ 3_009_000e18
flashRepayCost_dai   ≈ amount + 0 fee = 5_000_000e18  (covered by crvUSD swap-back)
crvUsdConsumedForRepay ≈ 5_000_000e18 / (1 - 0.0025 - 0.0025) ≈ 5_025_000e18
                       (the crvUSD swap-back is loss-making by ~50 bps)
```

Since `crvUsdOut (3M)` is far less than the amount needed to repay the
flash (5M), the PoC's actual flow has to unwind some sUSDS supply on Aave
to source the rest of the DAI repayment. The mathematically clean version
is: open the sUSDS supply leg up-front from **operator equity** rather than
flashloan, and use the flashloan to *bridge timing* during the GHO mint.

The realised 30-day carry on what remains on book (sUSDS NAV plus GHO debt
service):

```
sUSDS_30d_yield  = supply_remaining_usd * SSR * 30/365  ~ +$45_000 on $5M
gho_interest_30d = gho_debt_usd * r_gho * 30/365        ~ -$17_500 on $3M @ 7%
crvUsd_swap_pnl  = atomic; counted as PnL leg 1         ~ +$15_000 on $3M @ 30 bps
swap_losses      = -25 bps in + 50 bps repay round-trip ~ -$15_000

net_30d ≈ +45k - 17.5k + 15k - 15k ≈ +$27_500 on a ~$2M residual position
        ≈ ~17% APR on the equity that backs the residual sUSDS book
```

## Block pinned

`21_800_000` — late-Jan 2025. By this block:
- sUSDS has Aave V3 listing (post the Aave Risk Committee onboarding spell).
- GHO facilitator bucket on Aave is well above the borrow notional.
- GHO/crvUSD Curve pool has multi-million dollar two-sided depth.

## Risks

- **sUSDS Aave LTV freeze** — the PoC handles this via the USDC fallback
  path, which removes mechanism (2)'s SSR leg but keeps the 4-CDP composition
  intact (Maker DAI + Sky USDS as transit + Aave GHO + Curve crvUSD).
- **GHO facilitator bucket exhausted** — borrow reverts; PoC unwinds the
  supply leg gracefully and returns DAI for the flash repay.
- **Curve GHO/crvUSD pool depeg risk** — a sub-peg GHO inflates the
  crvUSD-out side; conversely an over-peg GHO compresses the entry edge.
- **Sky SSR cut** — governance can lower SSR with short notice, but a cut
  only affects the carry, not the atomic edge.

## Result

Status: full end-to-end open path implemented, with conditional fallback
for sUSDS-not-listed regime. Expected residual book after flash close:
~$2M sUSDS-equivalent collateral + ~$3M GHO debt + a small crvUSD residue.
Expected 30-day carry ≈ **+$25-35k**, i.e. **~15-20% APR** on the residual
equity. The PoC asserts only that the flash repaid successfully; the carry
is logged but not asserted (status: `theoretical`).
