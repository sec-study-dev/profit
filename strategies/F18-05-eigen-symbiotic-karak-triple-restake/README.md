# F18-05: Same-user triple-restake (EigenLayer + Symbiotic + Karak)

## Mechanism

Single user, three distinct restaking protocols, three different LST
deposits — all opened in one tx. Each restaking protocol independently
accrues its own points stream (EIGEN, SYMB, Karak points) on its own
deposited LST. The position-level alpha is that the *user is earning
all three protocols' loyalty/points simultaneously*, on distinct LST
units that nevertheless trace to the same underlying ETH.

The three restaking deposits at the pinned block:

1. **EigenLayer** — deposit **stETH** into EigenLayer's stETH strategy
   contract (`0x93c4b944D05dfe6df7645A86cd2206016c51564D`) via
   `StrategyManager.depositIntoStrategy()`. Accrues EIGEN points on a
   per-share basis.
2. **Symbiotic** — deposit **wstETH** into Symbiotic's `DefaultCollateral`
   wstETH vault (`0xC329400492c6ff2438472D4651Ad17389fCb843a`). Accrues
   SYMB points (later: SYMB token airdrop).
3. **Karak** — deposit **weETH** (EtherFi LRT) into Karak's
   `DelegationSupervisor` weETH vault. Karak's "K-points" stack on top
   of EtherFi's underlying EtherFi-points + native EigenLayer points
   (since EtherFi natively restakes through EigenLayer).

The composition forces three distinct LST source tokens into three
distinct restaking destinations. The user thus simultaneously earns:
- EIGEN points on Lido stETH (EigenLayer's stETH strategy),
- SYMB points on Lido wstETH (Symbiotic wstETH vault),
- Karak-points + EtherFi-points + EIGEN-points-via-EtherFi on weETH
  (Karak's weETH vault).

## Why it composes — the 3 mechanisms

1. **EigenLayer (StrategyManager)** — *native* restaking protocol,
   provides EIGEN-points for stETH deposits.
2. **Symbiotic (DefaultCollateral)** — *parallel* restaking protocol,
   provides SYMB-points for wstETH deposits. Symbiotic does not yet
   share strategy contracts with EigenLayer; the points are
   independent.
3. **Karak (DelegationSupervisor)** — *third-tier* restaking protocol,
   provides K-points and reroutes the deposited token's *underlying*
   protocol points to the user as well (e.g. weETH → EtherFi-points +
   EigenLayer-points).

No 2-mechanism combo achieves "3 restaking-protocol points on 3 LSTs":
- (EigenLayer + Symbiotic) is F15-04 (already shipped). Only 2 point
  streams.
- (EigenLayer + Karak) misses Symbiotic.
- (Symbiotic + Karak) misses EigenLayer-native.

The unique edge: **same user, three live restaking-protocol deposits,
none of which double-count** (each protocol tracks its own deposit base
independently).

## Preconditions

- Mainnet block ≥ Aug 2024 where all three restaking protocols are
  open for deposits (Karak's mainnet launch was July 2024). We pin
  **block 20,500,000** (mid-Aug 2024).
- Sufficient cap headroom in each vault. EigenLayer stETH strategy:
  uncapped at pinned block; Symbiotic wstETH vault: cap-managed,
  PoC try/catches; Karak weETH vault: cap-managed, PoC try/catches.

## Strategy steps (PoC)

1. Fund equity: 50 stETH + 50 wstETH + 50 weETH (each ≈ $150k at fork
   block, total ≈ $450k).
2. **Leg A (EigenLayer)**: `approve(stETH → StrategyManager); SM.depositIntoStrategy(STETH_STRATEGY, stETH, 50e18)`.
3. **Leg B (Symbiotic)**: `approve(wstETH → SymbioticVault); SymbioticVault.deposit(this, 50e18)`.
4. **Leg C (Karak)**: `approve(weETH → KarakVault); KarakVault.deposit(50e18, this)`.
5. PoC reports each leg's outstanding share/receipt amount.

## PnL math

This is a *points* strategy. Cash PnL on-chain at the pinned block is
**zero** (deposits, no token rewards yet flowing). Realised PnL is
off-chain at airdrop snapshot — typical per-protocol bid for "points"
in early 2024 (EtherFi, ezETH, Eigen) traded at **$0.03-$0.15 per
points-unit**, snapshot-determined.

Heuristic estimate (heavy uncertainty):
```
EIGEN_points_30d   ~ 50 stETH × 30d × 1 unit/eth-day = 1,500 units
SYMB_points_30d    ~ 50 wstETH × 30d × 1 unit/eth-day = 1,500 units
Karak_points_30d   ~ 50 weETH × 30d × 2 unit/eth-day = 3,000 units (boosted)

Per-point value (high uncertainty):
  $0.03 - $0.20 / point at snapshot-pricing for early-program LRTs.
```

Order-of-magnitude expected payout on $450k equity over 30 days:
**+$100 to +$2,000** in EIGEN, **+$50 to +$500** in SYMB, **+$300 to
+$1,500** in Karak-equivalent — total range **+$450 to +$4,000** with
3-4 orders of magnitude tail risk depending on per-protocol airdrop
pricing.

(This is points-class alpha; see F02-02 / F07-03 / F15-04 for similar
disclaimers.)

## Block pinned

**20,500,000** (mid-Aug 2024). All three restaking protocols are
operational. Karak's mainnet `DelegationSupervisor` was deployed in
July 2024.

## Risks

- **Vault cap exhaustion**: Symbiotic + Karak vaults gate deposits via
  a `limit()`. If exhausted at the fork block, the leg silently
  reverts (PoC try/catches and continues).
- **EigenLayer whitelisting**: at certain windows, EigenLayer's stETH
  strategy was deposit-frozen for non-LRT users (the "cap-race"
  pattern in F15-02). PoC checks `strategyIsWhitelistedForDeposit`
  first.
- **Withdrawal asymmetry**: Each protocol has a different withdrawal
  delay (EigenLayer: 7 days; Symbiotic: 7-14 days; Karak: 7 days). The
  position is illiquid on the way out.
- **Slashing risk**: post-AVS-live, each restake protocol can slash
  deposits independently. Cumulative slashing is the sum of each
  vault's slashing exposure.

## Result

Status: **mechanically-reproducible**. PoC opens each of three vault
deposits on the pinned block. Realised PnL is points-denominated and
off-chain at airdrop.

Expected aggregate payout on $450k equity over 30 days (very high
uncertainty): **+$500 to +$4,000 in points-equivalent value**. Cash PnL
at fork block: **$0** (this is points alpha, not cash alpha).
