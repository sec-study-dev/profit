# B15-02 — slisBNB · Wombat dynamic LP · Thena gauge bribe stack

## Family

B15 · 三协议机制堆叠. The BSC analogue of mainnet "LST + Curve + Convex"
yield-stacking patterns, anchored on slisBNB and Thena/Wombat — BSC's
ve(3,3) and dynamic-StableSwap protocols.

## Thesis

slisBNB has two unique BSC-native liquidity venues:

1. **Wombat** runs a *dynamic-asset-weight* StableSwap for the slisBNB/BNB
   pair — its LP token earns swap fees + WOM gauge emissions.
2. **Thena** runs a *ve(3,3) gauge* that can stake Wombat LP receipts (or
   the Wombat-LP-wrapped pair) and accrue THE emissions + bribes.

The triple-mechanism stack opens both at once:

1. **Lista StakeManager** — mint slisBNB at canonical rate (no AMM slip).
2. **Wombat `IWombatPool.deposit(slisBNB)`** — single-sided LP receipt
   that participates in *both* slisBNB↔BNB and slisBNB↔LP rebalancing
   flows, earning the haircut on every WBNB/slisBNB swap routed through
   Wombat.
3. **Thena `Voter.gauges(pool)` → gauge stake** — deposit the Wombat-LP
   receipt into Thena's gauge for the slisBNB pool, accruing THE emissions
   weighted by veTHE votes + external bribes paid by Lista to attract
   slisBNB liquidity.

Position-level yield:
- Wombat swap fees on the slisBNB asset (~0.5–1 % APR notional).
- WOM emissions (boostable with veWOM, ~5–15 % APR before bribes).
- THE emissions through Thena gauge (~10–25 % APR — Thena recently
  re-routed Lista bribes here).
- slisBNB native staking yield embedded in the LP asset (~3.2 % APR).

## Why it composes — the 3 mechanisms

1. **Lista StakeManager (canonical-rate LST mint)** — only path that
   converts BNB → slisBNB *without slippage*. Any other mint route (PCS,
   Thena AMM) pays haircut up-front, eroding the LP asset's effective
   yield.
2. **Wombat dynamic-asset StableSwap LP** — only BSC StableSwap that
   allows *single-sided* deposit + asymmetric rebalancing weights. Curve
   StableSwap (none deployed on BSC for slisBNB) requires balanced
   deposit. Wombat's design lets one-sided slisBNB liquidity earn fees
   from *every* slisBNB↔BNB swap.
3. **Thena Voter gauge stake** — Thena is the only ve(3,3) AMM on BSC
   with a *Wombat-LP gauge*. Staking the Wombat receipt into Thena's
   gauge converts WOM emissions exposure into THE + bribe exposure on
   top, without exiting the underlying LP.

**No 2-mechanism subset works:**
- (Lista + Wombat) alone misses THE emissions + bribe stream — leaves
  ~50 % of the total yield on the table.
- (Lista + Thena) alone (B08-class) — stakes slisBNB/BNB directly in a
  Thena Volatile or Stable pool but forgoes Wombat's dynamic-weight
  fee distribution.
- (Wombat + Thena) alone needs an entry point to slisBNB — without the
  canonical mint, AMM slip ≥ 10 bp at entry erodes weeks of yield.

The triple-stack uniquely sources the underlying LST at canonical rate,
captures Wombat's asymmetric fee tier, **and** layers Thena's vote-driven
bribe stream on top.

## Preconditions

- Wombat slisBNB/BNB pool live (deployed Q4-2023+).
- Thena gauge live for the Wombat slisBNB-LP token (verified via
  `Voter.gauges(pool)` returning non-zero).
- veTHE allocation already voted to the slisBNB gauge (otherwise THE
  emissions = 0; bribes still claimable).

## Strategy steps (PoC)

1. Fund 50 BNB equity.
2. **Leg A**: `IListaStakeManager.deposit{value: 50 BNB}` → ~50 slisBNB
   (canonical rate ignores accrual; live convertBnbToSnBnb gives the
   precise share count).
3. **Leg B**: `IWombatPool.deposit(slisBNB, 50e18, ..., shouldStake=false)`
   → receive Wombat slisBNB-LP receipt.
4. **Leg C**: query `IThenaVoter.gauges(pool)`; if non-zero, approve LP
   receipt to gauge and deposit. Gauge accrues THE.
5. Hold `HOLD_DAYS = 30`. Periodically claim:
   - `IThenaVoter.claimRewards(gauges, [[THE]])`
   - `IThenaVoter.claimBribes(externalBribes, [[USDT, lisUSD, WOM]], tokenId)`
   - slisBNB-share-price drift is captured automatically by the LP
     receipt's underlying asset accrual.
6. Report aggregate USD PnL.

## PnL math

50 BNB ≈ $30 000 equity, 30 days:
- Wombat fees (notional 0.7 % APR): 30 000 × 0.007 × 30/365 = **+$17**
- WOM emissions (boost 1.5×, 12 % APR): 30 000 × 0.18 × 30/365 = **+$444**
- THE emissions (gauge weight 0.5 %, 18 % effective APR):
  30 000 × 0.18 × 30/365 = **+$444**
- slisBNB-yield in LP (3.2 % APR on 50% of LP): 15 000 × 0.032 × 30/365 = **+$39**
- External bribes (Lista-paid, ~6 % APR claimable):
  30 000 × 0.06 × 30/365 = **+$148**

**Net: ≈ +$1 090 / 30 d / $30 k = ~44 % combined APR.**

Major uncertainty: Thena gauge vote weight is governance-determined and can
flip on weekly epochs.

## Block pinned

`FORK_BLOCK = 42_600_000` (Q1 2025; Wombat slisBNB pool was already in
production for > 12 months and Thena gauge mapping was live).

## Addresses used

- `BSC.LISTA_STAKE_MANAGER` (verified canonical exchange-rate)
- `BSC.WOMBAT_MAIN_POOL`, `BSC.WOMBAT_ROUTER` (// TODO verify)
- `BSC.slisBNB`, `BSC.WBNB`, `BSC.WOM`
- `BSC.THENA_PAIR_FACTORY`, `BSC.veTHE`, `BSC.THE`
- Thena Voter address resolved indirectly via `Voter.gauges(pool)` — the
  PoC reads `THENA_PAIR_FACTORY` then derives the gauge through
  `THENA_VOTER` — **inline placeholder** below.

## Risks

- **Wombat asset weight drift**: if slisBNB-weight blows above the
  pool's covered-weight cap, single-sided withdraw incurs a haircut
  (the design's "coverage-ratio penalty"). Mitigation: monitor pool
  coverage daily.
- **Thena gauge vote flip**: bribes/votes per epoch can move; PoC
  models a mid-range value.
- **WOM/THE emission decay**: both protocols have decaying emissions;
  10–20 % APR drop over the holding period is plausible.
- **slisBNB depeg**: a sustained slisBNB/BNB depeg widens the LP's
  impermanent-loss-equivalent and can flip the carry negative.

## Result

Status: **offline-draft**; compiles with try/catch on Wombat + Thena
calls. Expected PnL: **+$900 to +$1 200 / 30 d / $30 k notional** with
three live yield streams (Wombat fees + WOM, Thena gauge THE, external
bribes), plus the embedded slisBNB staking accrual.

## TODO

- Verify Wombat main-pool address + slisBNB asset address derivation.
- Resolve Thena Voter address and confirm gauge mapping for Wombat LPs
  (some ve(3,3) BSC forks gate this behind a separate `GaugeFactory`).
- Confirm `IThenaVoter.claimBribes` signature against the deployed Voter.
