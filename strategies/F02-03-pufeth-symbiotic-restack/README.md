# F02-03: pufETH stacked re-hypothecation (Karak / Symbiotic re-deposit)

## Mechanism
Puffer's **pufETH** is an ERC-4626 vault over wstETH (and stETH on legacy deposits)
whose underlying validators are EigenLayer-native restakers operated through
Puffer's anti-slashing module. pufETH itself earns:

- wstETH staking yield (Lido) — ~3.0%
- EigenLayer restaking points (Puffer is a major EL operator)
- **Puffer Carrot points** (own token, redeemable for PUFFER airdrop S1/S2)

The novel layer: pufETH was **whitelisted as a collateral asset on Symbiotic and
Karak Network**, both of which are alternative restaking protocols. Depositing
pufETH into a Karak vault or Symbiotic collateral pool yields:

- **Karak XP** (Karak airdrop)
- **Symbiotic points** (planned token + AVS-curator rewards)
- still earns Puffer + Lido points on the underlying

Result: **three to four overlapping point streams** for a single pufETH share, all
on the same notional collateral. To leverage, loop pufETH → borrow ETH on Morpho's
pufETH/WETH market → re-deposit ETH into Puffer.

## Why it composes
The point-streams of Lido, EigenLayer, Puffer Carrot, and Karak/Symbiotic are
**additive** — none is reduced when pufETH is re-deposited into a second restaking
network. A levered loop multiplies the additive stack by leverage factor.

```
total_point_yield_$ ≈ leverage × ( Lido_pts + EL_pts + Puffer_pts + Karak_pts )
```

Each stream's $/pt is independent. The loop is only economically rational if at
least one of them clears more than ~3-5% APR equivalent (loose cash spread cost).
Historical EIGEN, ETHFI airdrops both did; PUFFER and KARAK may.

## Preconditions
- Block: 19,800,000 (mid-April 2024 — Karak mainnet live, Symbiotic testnet
  active; PUFFER not yet launched, Carrots actively accumulating)
- Puffer pufETH share rate ≈ 1.005-1.010 wstETH (small premium since wstETH
  staking yield has accrued)
- Morpho pufETH/WETH market exists (Gauntlet-curated, 86% LLTV)
- Karak vault `K_pufETH` accepting deposits (caps not full)

## Strategy steps
1. Receive 100 WETH from user.
2. Unwrap to ETH, then stETH → wstETH via Lido + wrap. (Or buy wstETH on Curve.)
3. `IPufETH.depositWstETH(wstETHAmount, address(this))` → mint pufETH (1 share ≈
   1 wstETH initially).
4. **Karak deposit:** `IKarakVault.deposit(pufETH, recipient)` — pufETH stays
   collateral inside the vault, earning Karak XP. *Note: doing this BEFORE the
   loop locks tokens; for leverage, we Karak-stake the FINAL collateral position
   after looping. So skip step 4 for now and put it last.*
5. Loop on Morpho:
   - `supplyCollateral(pufETHMarket, allPufETH, ...)`
   - `borrow(WETH, ~75% of collateral value, ...)` (LLTV 86, conservative 75)
   - Unwrap WETH → ETH; back to step 2.
   - Repeat 3-4 times → ~3x leverage cleanly without flashloan, or use Morpho
     flashloan in one tx (preferred — see F02-01 pattern).
6. **Final Karak/Symbiotic re-deposit:** withdraw the looped pufETH FROM Morpho
   collateral is not possible (collateralised), so instead Karak/Symbiotic
   accept *the borrower's residual unencumbered pufETH* — typically the loop
   leaves ~5-10% pufETH idle which goes into Karak.

   *Refined strategy:* run the loop, but reserve **20%** of the final pufETH stack
   un-supplied to Morpho — deposit that 20% into Karak vault. This yields a layered
   stack where the bulk earns Lido+EL+Puffer pts levered, and the 20% slice earns
   the additional Karak XP.

## PnL math
Inputs: 100 ETH equity, 3x leverage on pufETH, 1-year hold.

```
End state:
  total pufETH = 300 (300 ETH-equiv)
  ETH borrowed = 200
  net equity   = 100 ETH

Cash leg (year 1):
  Lido yield on 300 pufETH      = 300 × 3.0%  =  9.0 ETH
  WETH borrow cost on 200 ETH   = 200 × 2.5%  = -5.0 ETH
  Net cash carry                = +4.0 ETH    ≈ +4% on equity
  (~$12,000 at ETH=$3000)

Point leg (year 1, three stacks):
  EigenLayer pts: 300 × ETH-day/year = 109,500 ETH-days
    → @ $2/ETH-day historical: ~$219,000
  Puffer Carrots: 300 × 100 carrots/ETH/day × 365 = 10.95M carrots
    → @ $0.005/carrot (PUFFER FDV $250M, supply 1B, 4% airdrop):
      ~$55,000
  Karak XP (on the unencumbered 20% slice = 60 pufETH):
    60 × 100 XP/ETH/day × 365 = 2.19M XP
    → @ $0.02/XP (early-mover premium): ~$44,000
  Symbiotic pts (alternative to Karak deposit; same slice): ~comparable, $40-60k
```

Combined estimate:
- Cash + realised points (base case): **+$330k/yr** on $300k equity (110% IRR)
- Bear (one point stream goes to zero): **+$150k** (50%)
- Worst (all points dilute or unlock late): **+$12k** (cash only, 4%)

## Block pinned
- Fork block 19,800,000 (mid-April 2024)
- Karak `pufETH` vault: `0xf9438f5da40Fb18bA5B690cf3d8B756e4Ddc7e60` — deployed
  under Karak VaultSupervisor `0x54e44dbb92dba848ace27f44c0cb4268981ef1cc`
  (https://etherscan.io/address/0x54e44dbb92dba848ace27f44c0cb4268981ef1cc).
  Reachable from app.karak.network/pool/ethereum/pufETH.
- Morpho pufETH/WETH market id: computed at runtime in `setUp()` from
  `keccak256(abi.encode(MarketParams{WETH, pufETH, MORPHO_ORACLE_PUFETH_WETH,
  AdaptiveCurveIRM, 0.86e18}))` and logged via `console2.logBytes32`.
- Morpho oracle (pufETH/WETH): `0xb9D9e07F36B6f3a14a4cf2A4dCC9B66Eb39603eC`.

## Risks
- **Anti-slashing failure.** Puffer's secure-signer module is a custom L2-style
  enforcement layer; bug could slash validator stack 100%.
- **Karak/Symbiotic immaturity.** Newer than EigenLayer; their AVS slashing
  conditions are less battle-tested.
- **Multi-protocol counterparty risk.** Stacking re-hypothecation adds linearly
  to attack surface: Lido + EL + Puffer + Karak/Symbiotic all must hold.
- **Withdrawal queue.** pufETH withdrawal via the Puffer pool has a queue;
  unwinding under stress requires DEX exit at a discount.
- **Point dilution & sybil clawback.** Same as F02-01/02; protocols routinely
  retro-adjust.

## Result
Status: **theoretical**. The loop mechanics are reproducible at this block, but
PUFFER/KARAK/SYMBIOTIC token values were not yet known.

PnL range (1y, 100 ETH equity):
- Cash only: **+$8-15k**
- Cash + one airdrop realised: **+$60-120k**
- Cash + full stack realised: **+$250-500k**
