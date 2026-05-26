# F16-04: GHO mint -> LUSD Stability Pool carry

## Mechanism

This strategy stacks two CDP yield mechanics that are denominated in
*different* stablecoins:

1. **Borrow GHO from Aave V3** at the governance-set variable rate (~9% APR
   in mid-2024). The collateral is USDC (or any Aave V3 supported asset).
   The borrower pays ~9% APR on the GHO debt.
2. **Swap the GHO into LUSD** via Curve (GHO -> crvUSD -> USDC -> LUSD route
   through the GHO/crvUSD StableNG pool, crvUSD/USDC NG, and the LUSD/3pool
   meta — no deep GHO/3CRV metapool exists on-chain).
3. **Deposit the LUSD into the Liquity v1 Stability Pool**. The Stability
   Pool earns:
   - **LQTY token emissions** — historically 30-50% APR equivalent,
     decaying linearly over 33 years (so ~25% in 2024).
   - **ETH gains** from liquidated troves. During calm weeks ETH gains are
     zero; during volatile weeks they can spike 5-10% in a day. Annualised
     average over 2023-2024 is ~2-4%.
   - **No interest** — depositors are not paid interest; LUSD in the SP
     accrues only the offset-from-liquidations & LQTY drip.

The cross-CDP basis here is:

```
carry = (LQTY_APR + avg_ETH_gain_APR) - r_GHO_borrow - swap_loss
```

Substituting 2024 values:

```
carry ≈ 25% (LQTY) + 3% (avg ETH gain) - 9% (GHO borrow) - 0.5% (swap)
      ≈ +18.5% APR on the LUSD principal
```

LQTY is the "fee token" of Liquity v1: a non-rebasing ERC-20 with two
on-chain yield sources (`LQTYStaking` contract pays out a slice of trove
issuance and redemption fees). LQTY emissions are deterministic — they
do not depend on protocol revenue — and historically the LQTY/USD price has
been the dominant uncertainty: emissions valued in USD have varied from
~$0.30 to ~$5.00 over 2022-2024.

The cross-CDP angle: **GHO debt is being used to finance an LUSD
stability-pool position**. Without GHO the operator would need their own
capital. With GHO they can leverage their existing USDC collateral to amplify
the LQTY+ETH-gain return. The two CDPs are uncorrelated — Aave's rate
engine is governance-driven, Liquity's stability-pool incentive schedule is
hardcoded — so the spread is structural rather than reflexive.

## Why it composes

GHO and LUSD are both CDP-issued stablecoins, but they sit on opposite ends
of the "debt yield" spectrum:

- **Aave/GHO**: pays the borrower's rate to GHO suppliers (currently
  the protocol itself — GHO has no third-party suppliers because
  `supply(GHO)` is disabled). GHO is a *pure debt instrument*: minted on
  borrow, burned on repay, no yield to holders.
- **Liquity/LUSD**: holders can deposit into the Stability Pool to absorb
  liquidations in exchange for LQTY emissions + ETH gains. The SP is the
  unique yield venue for LUSD.

The basis is sustained because Aave's GHO rate is calibrated to *Aave's*
incentives (TVL retention, peg defence) and ignores the Liquity ecosystem
entirely. When LQTY token incentives are richly priced (bull market), the
Stability Pool yield often exceeds GHO's borrow rate — at which point the
carry is positive on a USD-denominated basis.

## Preconditions

- Mainnet block with Aave V3 GHO live, USDC supply enabled, GHO bucket has
  headroom.
- Curve GHO/crvUSD (0x635EF0056A597D13863B73825CcA297236578595), crvUSD/USDC
  NG, and LUSD/3pool live with non-trivial depth.
- Liquity v1 Stability Pool live (it has been since trove genesis in 2021).
- LQTY emissions still flowing — they do not expire until ~2054.

PoC pins block **20_500_000** — Sep 12 2024.

## Strategy steps

1. Fund test contract with USDC collateral.
2. `supply` USDC to Aave V3 Pool.
3. `borrow` GHO at variable rate (rate mode = 2). Maintain LTV ~50%.
4. Swap GHO -> crvUSD via Curve GHO/crvUSD StableNG `exchange(0, 1, ...)`,
   then crvUSD -> USDC via crvUSD/USDC NG `exchange(0, 1, ...)`.
5. Swap USDC -> LUSD via Curve LUSD/3pool meta `exchange_underlying(2, 0, ...)`.
6. Approve LUSD to Liquity Stability Pool; `provideToSP(lusdAmount,
   frontEndTag=address(0))`.
7. Warp 30 days. Touch the SP to crystallise LQTY gain
   (`withdrawFromSP(0)` causes the pool to update the depositor's snapshot
   and pull pending LQTY + ETH gains).
8. Read `getCompoundedLUSDDeposit(this)`, LQTY balance, ETH balance.
9. Report carry as `(LQTY_value_usd + eth_gain_usd) - GHO_interest_owed`.

The PoC stops at step 8 and emits all relevant balances for analysis. The
optional close-the-loop step (repay GHO, withdraw USDC) is not executed
because it requires market-purchasing LUSD to rebuild the borrowed amount,
adding back-end depeg noise.

## PnL math

Let:
- `P` = USDC collateral = 200_000
- `LTV` = 50% -> GHO borrowed = 100_000
- `r_GHO` = 9.0% APR
- `swap_loss` = 30 bps round-trip GHO -> USDC -> LUSD = 300 USD
- `lqty_apr` = 25% (LQTY emissions valued at $1.00 / LQTY)
- `eth_gain_apr` = 3.0% (long-run average, year of low liquidations)
- `r_aUSDC` = 3.8% (Aave supply yield on the collateral side)
- horizon T = 30 days

```
gho_interest_30d = 100_000 * 0.09 * 30/365 = $739.7
lqty_30d         = 100_000 * 0.25 * 30/365 = $2_054.8
eth_gain_30d     = 100_000 * 0.03 * 30/365 = $246.6
ausdc_yield_30d  = 200_000 * 0.038 * 30/365 = $624.7

net_30d = lqty_30d + eth_gain_30d + ausdc_yield_30d - gho_interest_30d - swap_loss
        = 2054.8 + 246.6 + 624.7 - 739.7 - 300
        = $1886.4 / 30 days

annualised ≈ 22.9% APR on the $100k debt notional, or
            ≈ 11.5% APR on the $200k collateral base.
```

The dominant uncertainty is **LQTY price**: at $0.50/LQTY the carry halves;
at $0.30/LQTY (Liquity's bear-market floor) the carry drops to ~6% APR and
ETH-gain volatility dominates. The strategy should hedge LQTY by selling
emissions market-on-arrival.

## Block pinned

`20_500_000` — Aave GHO live with adequate bucket, Liquity SP TVL ~$80M
(non-saturated, full LQTY emissions accrue to pro-rata depositors).

## Risks

- **GHO rate hike**: AAVE governance can raise the rate with a 1-day timelock,
  compressing the carry.
- **Stability Pool gets emptied by a single big liquidation**: depositors
  see their LUSD balance *shrink* and an ETH gain instead. Whether this is
  net-positive depends on the discount at which the SP absorbed the
  liquidated trove. Historically SP buys ETH at ~10% discount to spot, so
  big liquidations are *good* events for SP depositors — but they crystallise
  the trade and force the operator to redeploy.
- **LQTY price collapse**: LQTY has thin secondary liquidity; the carry
  assumes LQTY ≈ $1. At $0.30 the trade is marginal.
- **Curve depeg on entry**: GHO/USDC and LUSD/USDC slippage at $100k notional
  is ~10 bps each; budgeted in `swap_loss`.

## Result

Status: full open path implemented end-to-end. Expected 30-day carry at
pinned-block parameters ≈ **+$1,500-2,000 on $100k GHO notional**, i.e.
~18-25% APR. Heavily LQTY-price-dependent; treat carry as a leveraged bet
on LQTY token value.
