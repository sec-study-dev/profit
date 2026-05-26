# F02-06: pufETH triple-stack — Puffer + Symbiotic DefaultCollateral + Aave eMode

## Mechanism
This strategy combines **three distinct DeFi mechanisms** on the same pufETH
notional to maximise the per-dollar point/yield surface:

1. **Puffer Finance LRT** — pufETH is an ERC-4626 over wstETH; underlying earns
   Lido stETH yield + EigenLayer native restaking pts + Puffer Carrots.
2. **Symbiotic DefaultCollateral** — Symbiotic's collateral primitive is a thin
   ERC-20 wrapper that lets the holder participate in network-level slashing
   while earning **Symbiotic points** + curator (Mellow/Gauntlet) rewards. Even
   though no canonical pufETH DC exists at this block, we Symbiotic-stake a
   correlated *wstETH* slice via `DC_wstETH` (0xc329400492...) — Puffer's own
   underlying. Result: the wstETH leg double-earns Lido + Symbiotic pts.
3. **Aave V3 eMode (ETH-correlated, cat 1)** — pufETH was added to Aave's
   ETH-correlated eMode in mid-2024 (LTV 92.5%, LT 95%). This lets the strategy
   borrow WETH at high LTV against pufETH and loop.

Conceptually:
```
                      ┌───────── Aave eMode ──────────┐
                      │                                │
   100 ETH equity ─→ split ─→ ─ pufETH (75 %) ──→ supply ──→ borrow ETH (loop)
                              │
                              └─ wstETH (25 %) ──→ DC_wstETH (Symbiotic)
```

## Why it composes (3 mechanisms, non-overlapping)
- **Puffer/EL points** credit on pufETH spot supply (Aave aPufETH still counts in
  Puffer's tracker per their docs; verify at runtime).
- **Symbiotic points** are paid on DC-locked wstETH (different protocol than
  EigenLayer; not zero-sum).
- **Aave eMode** delivers ~10x leverage on the pufETH leg without touching the
  DC_wstETH leg (the latter is unencumbered).

This is structurally distinct from F02-03 (which used Morpho flashloan + Karak
on the *same* pufETH unit). Here the second restaker is **Symbiotic** (not
Karak), and the leverage source is **Aave eMode** (not Morpho flash).

## Preconditions
- Block: 20_100_000 (early June 2024). At this block:
  - pufETH live on Aave V3 mainnet in ETH-correlated eMode (added 2024-05).
  - Symbiotic DefaultCollateral `DC_wstETH` live (`0xc329400492c6ff...`).
  - Puffer L1 caps not full.
- Aave WETH variable borrow ~3.0-3.5%; pufETH supply share ~0.5-1.0%.

## Strategy steps
1. Receive 100 WETH equity.
2. Unwrap to ETH; mint stETH via Lido → wrap to wstETH (100 wstETH-equiv).
3. **Split** the wstETH 75/25:
   a. **75 wstETH → pufETH**: `IPufETH.depositWstETH(75 wstETH, this)` →
      receive ~75 pufETH (initial rate ≈ 1.000-1.005).
   b. **25 wstETH → Symbiotic DC_wstETH**: approve + `DC.deposit(this, 25e18)`
      mints DC_wstETH; underlying Lido yield is preserved, Symbiotic pts accrue.
4. Set Aave eMode category 1 (ETH correlated): `setUserEMode(1)`.
5. Supply pufETH to Aave: `supply(pufETH, 75e18, this, 0)`,
   `setUserUseReserveAsCollateral(pufETH, true)`.
6. Iterative loop (5 rounds at 85% per-round LTV against 92.5% cap):
   a. `getUserAccountData()` → availableBorrowsBase.
   b. `borrow(WETH, ~85% of avail, 2, 0, this)` (variable rate).
   c. Convert WETH → stETH (Lido) → wstETH → pufETH (`depositWstETH`).
   d. Supply new pufETH.
7. Hold; PnL realised over time via Lido yield, Puffer pts, EL pts, Symbiotic pts,
   minus Aave WETH borrow cost.

## PnL math
Inputs: 100 ETH equity, 8x leverage on pufETH leg, 25 wstETH on Symbiotic, 1y.

```
End state:
  pufETH on Aave    = 600 (≈ 612 wstETH-equiv, ≈ 715 ETH-equiv after Lido yield)
  Aave WETH debt    = 525 ETH
  DC_wstETH         = 25 wstETH-equiv (≈ 29.2 ETH)
  Net equity        = 100 ETH

Cash leg (1 year):
  Lido yield through pufETH:  612 × 3.0%    = +18.4 ETH
  Aave WETH borrow cost:      525 × 3.2%    = -16.8 ETH
  DC_wstETH Lido yield:        25 × 3.0%    =  +0.75 ETH
  Net cash carry              ≈ +2.4 ETH (~+2.4% on equity ≈ $7,200)

Point legs (1 year):
  Puffer Carrots: 600 × 100/day × 365 = 21.9M Carrots
    @ $0.005/Carrot (PUFFER airdrop est) ≈ $109,500
  EL rs-pts:      600 × 1 ETH-day × 365 = 219,000 ETH-days
    @ $2/ETH-day (S1 historical)         ≈ $438,000
    @ $0.5/ETH-day (S2 dilution)         ≈ $109,500
  Symbiotic pts on DC_wstETH (25 wstETH):
    Pre-TGE: ~250k Symbiotic pts/yr @ $0.05/pt (TGE est) ≈ $12,500
  Mellow/Gauntlet curator boost (if DC routes to a curated vault) ~$5-15k.
```

Outcome on 100 ETH ($300k) equity (1y):
- Cash only: **+$7k** (+2.4%)
- Cash + base points: **+$240k** (+80%)
- Cash + bull (full EL airdrop at S1 multiple): **+$580k** (+193%)
- Bear (one stream → 0): **+$40-100k**

## Block pinned
- Fork block 20,100,000 (early June 2024).
- Symbiotic `DC_wstETH`: `0xc329400492c6ff2438472D4651Ad17389fCb843a`
  (https://etherscan.io/address/0xc329400492c6ff2438472d4651ad17389fcb843a).
- Aave V3 Pool: `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`.
- Aave eMode category 1 = "ETH correlated" (genesis payload).
- pufETH: `0xD9A442856C234a39a81a089C06451EBaa4306a72`.

## Risks
- **Aave eMode reduction.** If governance moves pufETH out of cat 1 (e.g. due to
  Puffer slashing event), the LTV collapse forces unwind at potential loss.
- **Puffer slashing.** Anti-slashing module is custom L2-style code; bug = 100% loss.
- **Symbiotic slashing.** DC_wstETH is exposed to network-level slashing once
  delegated to operators; a slash burns the underlying.
- **Cash-spread inversion.** Aave WETH borrow rate has historically touched 8-10%
  during unwinds; at 8x leverage that's -45 ETH/yr — catastrophic if sustained.
- **Lido + EL + Puffer + Symbiotic stack risk.** Five protocols compose.
- **Point dilution / clawback.** All point issuers can retroactively re-rate.

## Result
Status: **theoretical**. Mechanics are reproducible at the pinned block; the
Symbiotic leg is an unencumbered side-stack (always recoverable). PnL dominated
by EL + Puffer airdrop realisation.

PnL range (1y, $300k notional):
- Cash only: **+$5-10k**
- Cash + realised points (base): **+$200-300k**
- Cash + bull (EL S1 multiple): **+$550k+**
- Bear (point streams → 0 + borrow spike): **-$50k**
