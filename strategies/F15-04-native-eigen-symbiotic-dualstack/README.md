# F15-04: Native EigenLayer restake + Symbiotic dual-stack

## Mechanism

Symbiotic (live mainnet from June 2024) is a competing restaking primitive
that accepts a wider set of collateral than EigenLayer — including wstETH,
cbETH, sUSDe, ENA, plus LRTs (sfrxETH-LRT, mev-eth-LRT). Each collateral
type has a per-network "vault" implementing the Symbiotic Collateral interface.

The dual-stack thesis: the **same wstETH balance** can earn:

1. **Native EigenLayer points** via `StrategyManager.depositIntoStrategy(
   wstETH_strategy, wstETH, amount)`
   - wstETH strategy: `0x93c4b944D05dfe6df7645A86cd2206016c51564D` is stETH;
     the **wstETH strategy** is a distinct proxy. EigenLayer's beacon-chain-only
     model means wstETH itself is NOT a registered strategy at the early-2024
     blocks. **The wstETH→EL path goes through stETH unwrap.** Verified via
     EL docs.
2. **Symbiotic restaking points** via depositing wstETH into the Symbiotic
   wstETH vault.

These are **NOT** the same balance — depositing into EL consumes the wstETH.
The real dual-stack is to **split the position**:

- 50% wstETH unwrapped to stETH and deposited into EigenLayer stETH strategy.
- 50% wstETH deposited directly into Symbiotic wstETH vault.

Both legs earn their respective protocol's points + AVS rewards. The compose
value is **point-diversification**: if EIGEN airdrop disappoints, Symbiotic
backstops; if Symbiotic governance falters, EigenLayer carries.

## Why it composes

Point streams are additive on the protocol level — neither protocol reduces
points if the user is also deposited in the other. The compose is therefore
**not capital-efficient leverage**, but **point-stack diversification under
the same notional risk** (both protocols expose the user to slashing risk
on the underlying restaked validators, but the slashing conditions differ).

## Preconditions

- Block: 20,400,000 (early Aug 2024 — Symbiotic mainnet live, wstETH vault
  accepting deposits).
- Symbiotic wstETH vault address (verified via Symbiotic docs + Etherscan
  label "Symbiotic: DefaultCollateral wstETH"):
  `0xC329400492c6ff2438472D4651Ad17389fCb843a` — the canonical wstETH
  `DefaultCollateral` vault from Symbiotic's June-2024 mainnet launch. Cap
  is governance-managed; if the cap is full at FORK_BLOCK the PoC's
  try/catch falls through and Leg A still completes.
- EigenLayer stETH strategy address: `0x93c4b944D05dfe6df7645A86cd2206016c51564D`.
- A wstETH whale for funding (wstETH is non-rebasing, so `deal()` works).

## Strategy steps

1. Fund test contract with 100 wstETH (`deal` works for wstETH).
2. Snapshot PnL.
3. **Leg A (50 wstETH → EigenLayer stETH strategy):**
   - Unwrap 50 wstETH → stETH (`IWstETH.unwrap`).
   - Approve stETH to `EIGEN_STRATEGY_MANAGER`.
   - `depositIntoStrategy(STETH_STRATEGY, stETH, stETHAmount)`.
4. **Leg B (50 wstETH → Symbiotic vault):**
   - Approve wstETH to Symbiotic vault.
   - `IDefaultCollateral.deposit(recipient, amount)` — Symbiotic's
     `DefaultCollateral` interface (ERC-4626-flavoured but with explicit
     `recipient` arg).
   - If vault rejects (paused / cap) — log & skip; the EigenLayer leg
     still completes.
5. End PnL.

## PnL math

```
100 wstETH equity (≈ 100 × 1.16 = 116 stETH-equiv ≈ $348k @ $3k ETH)

Leg A: 50 wstETH = ~58 stETH in EL stETH strategy.
  Lido yield     58 × 3.0%     = 1.74 stETH ≈ $5,220
  EL points      58 × 1pt/d × 365 = 21,170 pts
    @ $3.50/pt   ≈ $74,100
  AVS rewards    58 × 0.5%     = ~$870
  Subtotal:                    ≈ $80,000

Leg B: 50 wstETH in Symbiotic.
  Lido yield (wstETH compounding) 50 × 3.0% = 1.5 wstETH ≈ $5,220
  Symbiotic points 50 wstETH × 100 pts/wstETH/d × 365 = 1,825,000 pts
    @ $0.02/pt (early-listing premium)  ≈ $36,500
  AVS-curator rewards (Mellow): ~0.4% on wstETH  ≈ $1,400
  Subtotal:                    ≈ $43,100

Total (1y): ~$123,000 on $348k equity (35%/yr).
Same notional in pure EigenLayer (no diversification):
  100 wstETH × 116% × $3,000 × 35%-equiv = ~$160k point-heavy bet
  (but concentrated single-airdrop risk)
```

Diversified result is **lower expected return** but **lower variance**.
This is the Markowitz argument for restaking.

## Block pinned

- Fork block: 20,400,000.
- Symbiotic vault address (verified, see preconditions):
  `0xC329400492c6ff2438472D4651Ad17389fCb843a`.

## Risks

- **Symbiotic vault address may differ.** Mellow + multiple curators deploy
  Symbiotic vaults; the canonical wstETH curator vault changed at least
  once during 2024. The PoC wraps Leg B in try/catch.
- **Slashing-condition overlap.** If both protocols slash on similar
  conditions (Casper-FFG double-vote etc), the "diversification" is
  illusory.
- **Point-token launches.** SYMB token has not launched at fork-time; the
  $/pt is a forward-looking assumption.
- **Symbiotic cap.** Like EL, Symbiotic enforces per-vault caps. Leg B may
  revert if the cap is full at fork-time.

## Result

Status: **theoretical / mechanics-reproducible.** Both legs execute at the
fork block (subject to Symbiotic vault address verification). Forward 1y
dollar PnL depends on EIGEN + SYMB price assumptions documented above.

PnL (1y, 100 wstETH equity ≈ $348k):
- Bull (both airdrops realise): ~+$123k (35% return).
- Base (one disappoints): ~+$50-70k.
- Bear (both heavily diluted): ~+$10k (cash yield only).
