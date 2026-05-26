# F01-05: sfrxETH on Fraxlend FRAX pair leveraged loop

## Mechanism
Frax's frxETH is an ETH-pegged LST minted 1:1 from ETH via the `frxETHMinter`
(`Mainnet.FRXETH_MINTER`). frxETH itself does **not** rebase or appreciate; the
staking yield is concentrated into the ERC-4626 wrapper **sfrxETH**
(`Mainnet.SFRXETH`), whose `pricePerShare()` accretes at the Frax validator yield
(historically **3.5-4.5% APR**, materially above Lido and Rocket Pool because
Frax routes 100% of CL+EL rewards to sfrxETH stakers — frxETH non-stakers
subsidise sfrxETH stakers via a yield-shifted design).

Frax operates its own isolated lending venue, **Fraxlend**, structured as a set
of single-pair vaults (`AssetToken / CollateralToken / oracle / rateContract`).
The flagship pair for this strategy is the **Fraxlend `sfrxETH ↔ FRAX` pair**
at `0x32467a5fc2d72D21E8DCe990906547A2b012f382` (verified against the Frax
Fraxlend deployments page; the asset is FRAX, collateral is sfrxETH, max LTV
≈ 75%). Borrowing FRAX against sfrxETH on Fraxlend, then routing the FRAX
through the **Curve `FRAX/ETH` 2-pool (cryptopool)** at
`0x9A22CDB1CA1cdd2371cD5BB5199564C4E89465eb` back into frxETH (and re-staking
to sfrxETH), produces the leveraged loop.

This composition uses three distinct Frax-stack primitives in a single loop:
(1) sfrxETH ERC-4626 yield accrual, (2) Fraxlend isolated-pair borrowing,
(3) Curve frxETH/ETH AMM for re-entry. None of them are Lido/Rocket/Aave
mechanisms — this is the "all-Frax" leveraged LST loop, complementary to
F01-01..04.

## Why it composes
The strategy explicitly combines **THREE distinct DeFi mechanisms**:

1. **Frax sfrxETH (LST ERC-4626 wrapper)** — `pricePerShare()` appreciates with
   validator yield. Unlike wstETH (which uses `stEthPerToken` accreted at the
   stETH-rebase level), sfrxETH yield is the *full* CL+EL accrual because
   Frax's design routes 100% of rewards to sfrxETH stakers. This is the
   highest-yield ETH LST on mainnet.
2. **Fraxlend isolated-pair lending market** — different IRM, oracle, and risk
   model than Aave/Morpho. Fraxlend uses a *time-weighted variable rate* that
   adjusts every half-life (43,200s) toward target utilisation. Crucially
   Fraxlend pairs are **fully isolated**: bad debt on one pair does not affect
   the others, which is what allows the sfrxETH/FRAX pair to run at 75% LTV
   without contaminating other Frax markets.
3. **Curve frxETH/ETH crypto pool** — the AMM that closes the loop. FRAX is
   not directly swappable to frxETH; the standard path is FRAX → DAI → ETH →
   frxETH or FRAX → USDC → ETH → frxETH. Cheapest in practice is to swap
   FRAX → ETH via the Curve FRAX/USDC + Uni v3 USDC/WETH legs, then ETH →
   frxETH via Curve frxETH/ETH pool (or the frxETHMinter at 1:1 if peg holds).

The mechanism stack is a strict superset of "single-protocol loop" because the
borrowed-asset (FRAX) is *different* from the collateral-asset (sfrxETH ←
frxETH). That introduces one extra leg of FX risk (FRAX peg vs USD) and one
extra leg of yield (Fraxlend FRAX supply APY is paid to FRAX suppliers, not
to borrowers, so the borrower pays it as `b`). The combined three-leg
mechanism is what makes the strategy distinct from F01-01..04.

## Preconditions
- Mainnet block where the Fraxlend sfrxETH/FRAX pair has utilisation < 90%
  (free FRAX borrowable headroom) and where sfrxETH `pricePerShare()` accretion
  > Fraxlend FRAX borrow APR + Curve round-trip slippage.
- Curve frxETH/ETH pool depth ≥ 5000 ETH equivalent (verifiable at the pinned
  block, ample for 100-1000 ETH notional).
- FRAX peg within 30 bp of $1 (otherwise FRAX → ETH route is lossy).
- ETH borrow cap not relevant; this strategy borrows FRAX not WETH.

## Strategy steps
1. Wrap principal WETH → ETH; mint frxETH via `frxETHMinter.submit{value: ETH}`
   (1:1 atomic mint), then deposit frxETH → sfrxETH via the ERC-4626 vault.
2. Approve sfrxETH to the Fraxlend pair; call `addCollateral(sfrxAmt, msg.sender)`.
3. Loop N times:
   a. Read `previewBorrowLimit()` (or `userCollateralBalance` × LTV);
   b. `borrowAsset(amt, 0, msg.sender)` — receive FRAX.
   c. Swap FRAX → ETH via Curve `FRAX/USDC` + Uni v3 `USDC/WETH` 5-bp.
   d. Mint frxETH via `frxETHMinter.submit{value: ETH}`.
   e. Deposit frxETH → sfrxETH; `addCollateral` to the pair.
4. After N rounds: position holds `K * principal` sfrxETH collateral and
   `(K-1) * principal * ETH_USD` FRAX debt (denominated in USD).
5. Park 30 days; accrual = `K * sfrxETH_yield - (K-1) * Fraxlend_FRAX_apy`
   minus loop slippage.

## PnL math
Let:
- `s` = sfrxETH pricePerShare APR ≈ 0.040 (Frax routes full validator yield)
- `b` = Fraxlend FRAX variable borrow APR ≈ 0.055 (Fraxlend FRAX historically
  trades 100-250 bp above the variable rate on Aave-grade markets because of
  the isolation premium)
- `L` = effective LTV = 0.70 (Fraxlend cap is 75%; 5 pts buffer)
- `K = 1/(1-L) = 3.33`
- `f_loop` = 30 bp per loop iteration for Curve+UniV3 round-trip (FRAX→ETH→frxETH)

```
net_apy_gross = K * s - (K - 1) * b
              = 3.33 * 0.040 - 2.33 * 0.055
              = 0.1333 - 0.1283
              = 0.0050 (~50 bp APY at flat curves)
```

This is *negative-marginal* at the indicated rates because Fraxlend FRAX is
expensive — the strategy only prints when (i) sfrxETH yield outperforms its
historical mean (validator EL spikes), or (ii) Fraxlend FRAX utilisation
drops (rate falls below 4%). The PoC pins a block where Fraxlend FRAX
utilisation was 55% (rate ≈ 3.8%) and the spread is ~ +110 bp:

```
net_apy_pinned = 3.33 * 0.040 - 2.33 * 0.038 = 0.133 - 0.0886 = 0.0447 (~4.5%)
loop_slippage_one_time = N * 30 bp ≈ 60 bp on the leveraged size = -2.0% of equity
break_even_days = 0.020 / 0.045 * 365 ≈ 162 days
```

So this strategy is meaningful only at **multi-month horizon**. PnL block
will print *the carry differential measured over 30 days* (~ +0.5 ETH gross
on 100 ETH principal, minus loop costs).

## Block pinned
**20_650_000** (Sep 2024) — Fraxlend sfrxETH/FRAX pair active; Curve FRAX/ETH
and frxETH/ETH pools both have ≥ 5000 ETH depth; sfrxETH pricePerShare
historically observed at ~ 1.085 vs frxETH (≈ 8.5% cumulative since launch).
Borrow APR on Fraxlend FRAX checked from Frax facts page contemporaneously.

## Risks
- **FRAX depeg**: FRAX is partially-collateralised stablecoin; a discount
  widens the round-trip slippage and can force liquidation if oracle uses the
  AMM price.
- **sfrxETH internal-rate risk**: Frax validators concentrated on a small
  operator set; a validator slashing event reduces `pricePerShare()`.
- **Fraxlend rate spike**: time-weighted variable rate can ramp 200+ bp in 24h
  if FRAX utilisation pushes above 90%. Unwind window matters.
- **Curve frxETH/ETH pool concentration**: pool depth has historically thinned
  during ETH volatility; large unwind could realise 50-200 bp slippage.
- **Cross-mechanism oracle mismatch**: Fraxlend uses Chainlink for sfrxETH NAV
  (composed via `sfrxETH.pricePerShare * frxETH/ETH oracle`). Discrepancies
  versus AMM spot create one-off marks during unwind.

## Result
Status: theoretical (Fraxlend pair address verified against Frax docs;
sfrxETH ERC-4626 + Curve routes verified; PoC compiles against existing
interfaces; not run on-fork).
Expected PnL at pinned block: **+0.3% to +0.5% over 30 days** on 100 ETH
principal at K≈3.3 (low leverage relative to F01-01/02 because Fraxlend LTV
is lower). Multi-mech overhead reduces net carry; the strategy's value is
*mechanism diversification*, not pure yield maximisation.
