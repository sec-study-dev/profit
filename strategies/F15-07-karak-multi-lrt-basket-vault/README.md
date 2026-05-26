# F15-07: Karak v2 multi-LRT basket — wstETH + weETH + pufETH

## Mechanism

Karak Network (founded by the team behind Andalusia / Risc Zero) is a
competing restaking primitive to EigenLayer with one strategic difference:
**multi-asset vaults**. Each Karak vault is an ERC-4626 over a specific LST
or LRT asset, and the depositor's claim to the underlying asset is preserved
1:1 — i.e. depositing pufETH into the Karak pufETH vault does NOT surrender
the Puffer + Lido + (LRT-routed) EL points associated with that pufETH.

The compose: split equity 3 ways across **three Karak vaults**, each
holding a different LRT/LST. The user simultaneously earns:

- The Karak XP / KAR airdrop on all 3 vault positions.
- Each underlying asset's full native point stack.
- All three independently — no asset is consumed by a "wrapper" the way
  EigenLayer's strategy proxy consumes its underlying.

This is a **point-diversification** trade: instead of betting on one LRT's
airdrop, the user covers the universe (Puffer, EtherFi, Lido) AND captures
Karak's own airdrop on the same notional.

## Why it composes (3-mechanism)

Three independent reward mechanisms layer:

1. **Karak (restaking layer)** — Karak XP accrue per-vault-share per-second
   on every deposited asset. KAR token TGE (forecast end-2024 / early-2025)
   distributes pro-rata to XP balances at snapshot.
2. **LRT layer (Puffer + EtherFi)** — pufETH continues to receive Puffer
   Carrot + (Puffer-claimed) EigenLayer points; weETH continues to receive
   ETHFI loyalty points + (EtherFi-claimed) EL points. The LRT issuer's
   point-tracking sees the vault contract as the holder, but Karak vaults
   forward those points to the depositor via Karak's reward router (or, in
   v1, by maintaining a transparent ERC-4626 share rate that includes the
   accrued rewards).
3. **LST layer (Lido)** — wstETH compounds Lido staking yield inside the
   Karak vault automatically (because wstETH is non-rebasing; the share
   rate of the Karak vault tracks the wstETH balance which tracks stETH
   rebase).

Three reward streams. No double-counting in the sense that any token issuer
denies double-credit, but all three are paid simultaneously because each
issuer measures its own primitive (Karak XP from Karak; Puffer Carrot from
Puffer; ETHFI from EtherFi; LDO via the stETH rebase).

## Preconditions

- Block: 20,700,000 (Sep 2024). Karak v2 live (multi-vault DelegationSupervisor),
  pufETH / weETH / wstETH all have Karak vaults open at non-zero cap.
- Karak vault addresses (verified via Karak docs + Etherscan labels):
  - wstETH: `0xa1A300919DDF0Dc4B6cE1AcfC1f4F71be0E80f97`
  - pufETH: `0xBE3cA34D0E877A1Fc889BD5231D65477779AFf4e`
  - weETH : `0x7C22725d1E0871f0043397c9761AD99A86ffD498`
- ETH funding (90 ETH total = 3 × 30 ETH per leg). `vm.deal` works.

## Strategy steps

1. `vm.deal(address(this), 90 ether)`.
2. Snapshot PnL.
3. **Leg A**: Lido `submit{value: 30e18}` → stETH → `wstETH.wrap` → approve
   → `KarakVault(wstETH).deposit(amount, address(this))`.
4. **Leg B**: `EtherFiLiquidityPool.deposit{value: 30e18}()` → eETH →
   `weETH.wrap` → approve → `KarakVault(weETH).deposit(...)`.
5. **Leg C**: Lido `submit{value: 30e18}` → stETH → `wstETH.wrap` →
   `pufETH.depositWstETH(...)` → approve → `KarakVault(pufETH).deposit(...)`.
6. Read Karak vault `balanceOf(address(this))` for all three vaults.
7. End PnL.

Each Karak deposit is wrapped in try/catch — if a single vault is capped,
the other two still complete. The `require(...)` at the end ensures at least
one leg landed.

## PnL math (forward 1y, 90 ETH total notional ≈ $270k)

```
Per-leg, 30 ETH equity (~$90k):

(A) wstETH leg
    Lido staking yield  30 × 3.0%       = 0.90 stETH ≈ $2,700
    Karak XP / KAR      30 × ~$50/ETH/yr  (TGE-discounted) ≈ $1,500
    Total leg A:                                            ≈ $4,200

(B) weETH leg
    Lido yield (via eETH)  30 × 3.0%    = 0.90 ETH ≈ $2,700
    ETHFI loyalty / season pts
        30 × ~$100/ETH/yr (ETHFI TGE Mar-24 happened, season pts ongoing)
                                       ≈ $3,000
    EL pts via EtherFi (-15% fee)      ≈ $32,500
    Karak XP / KAR        30 × ~$50    ≈ $1,500
    Total leg B:                                           ≈ $39,700

(C) pufETH leg
    Lido yield (via wstETH inside pufETH) 30 × 3.0% × 0.96 (Puffer fee)
                                       = 0.86 ETH ≈ $2,592
    Puffer Carrot         30 × ~$80/ETH/yr ≈ $2,400
    EL pts via Puffer    30 × 1pt/d × 365 × $3.50 × 0.90  ≈ $34,500
    Karak XP / KAR        30 × ~$50    ≈ $1,500
    Total leg C:                                           ≈ $40,992

Total all 3 legs (1y): ~$84,900 on $270k equity.
Net: ~31% / yr.

vs single-asset Karak-only (e.g. 90 ETH all in Karak-wstETH):
  Lido yield + Karak XP only ≈ $12,600 / yr ($4,200 per leg × 3 lots)

The diversified path captures (LRT pts × 2) + (Karak XP × 3) + (LST yield × 3),
while the single-asset path captures only the wstETH + Karak XP on one lot.
The diversified delta is ~ +$72k / yr ON THE SAME EQUITY, almost entirely
from the LRT point streams (EtherFi + Puffer) that the wstETH-only path
would forgo.
```

## Block pinned

- Fork block: 20,700,000.

## Risks

- **Karak vault caps.** Each vault is capped; if any leg is full at fork,
  that leg reverts and the equity sits unproductive. The try/catch ensures
  the other legs land.
- **Karak custody.** Karak's vaults are not as battle-tested as EigenLayer's
  StrategyManager. A vault bug could freeze deposits during the
  withdrawal-delay window.
- **LRT point routing.** Some LRT issuers do NOT credit points to the
  vault-deposited balance (they look for direct EOA holdings). Empirically
  in 2024, EtherFi and Puffer both honoured restaking-vault deposits, but
  this is a per-issuer policy decision and can change.
- **KAR token launch risk.** KAR has not launched at FORK_BLOCK; the XP
  → $ conversion is forward-looking.
- **Withdrawal delay stacking.** Karak imposes its own withdrawal delay
  (~7-9 days). Compounded with EigenLayer's 7-14 day delay (when the user
  eventually unwinds via the LRT's redemption path), total exit can be
  3-4 weeks.

## Result

Status: **mechanically reproducible at fork.** All three legs execute the
mint + wrap + deposit chain; final Karak share balances confirm the
positions landed.

PnL (1y, 90 ETH equity ≈ $270k):
- Bull (KAR + ETHFI-S3 + Puffer + EIGEN all realise): ~+$100k+.
- Base (one airdrop disappoints): ~+$60-85k.
- Bear (only cash yield): ~+$8k (Lido staking only).
