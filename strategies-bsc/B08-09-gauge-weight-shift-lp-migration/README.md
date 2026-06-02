# B08-09: Gauge-weight-shift LP migration Thena ↔ PCS (3-mechanism)

## Mechanism
Every Thursday Thena's `Voter.distribute()` writes new `rewardRate(token)`
values into each gauge based on the previous epoch's vote weights.
A pool whose share drops sees its $/TVL emission collapse correspondingly.

The same underlying pool (slisBNB/WBNB) is gauged on both Thena and PCS
v2. PCS v2 emissions are set by `MasterChefV2.allocPoint`, updated
much less frequently. When Thena weight drops while PCS weight is
unchanged, **the optimal LP allocation shifts**.

Strategy:
- **Epoch N**: 100 % capital in Thena gauge (higher APR).
- **At distribute()**: read new Thena `rewardRate`, compare to PCS allocPoint.
- **If gap > 800 bps**: migrate 60 % to PCS LP.
- **Epoch N+1**: harvest both legs at new optimal allocation.

3 mechanisms stacked:
1. Thena gauge entry (B08-01 style).
2. PCS v2 gauge entry (B08-05 style).
3. **Cross-gauge migration logic** — reads on-chain rates and rebalances.

## Why it composes
- Thena vote redistribution is **public + instantaneous** at epoch close.
- PCS allocPoint changes are **governance-gated** (slow timelock).
- The information asymmetry between fast (Thena) and slow (PCS) gauge
  systems creates a window where one is mispriced relative to the other.
- Bots that watch only one protocol miss it; a cross-protocol harness
  captures the spread.

## Preconditions
- Both protocols have **liquid LP markets** for slisBNB/WBNB at pinned
  block.
- Migration cost (gas + slippage) < expected APR uplift over remaining
  epoch (35 bps round-trip is the modeled cost — meets the threshold
  at $180k notional).
- PCS gauge has not yet adjusted to match Thena's new vote distribution.

## Numbers (THE=$0.30, CAKE=$2.40, BNB=$600)
- Principal: 300 BNB = **$180 000**.
- **Epoch N (100 % in Thena, APR 45 %)**:
  - Yield: $180k × 45 % × 7/365 = **$1 553/wk** = 5 178 THE.
- **Epoch N+1 vote redistribution**:
  - Thena APR drops to 18 % (60 % cut in rewardRate).
  - PCS APR remains 27 %.
  - Gap: 900 bps > 800 bps threshold → migrate 60 %.
- **Epoch N+1 realized yield (post-migration)**:
  - Thena leg (40 %): $72k × 18 % × 7/365 = **$249/wk**.
  - PCS leg (60 %): $108k × 27 % × 7/365 = **$560/wk**.
  - **Realized total: $809/wk**.
- **Counterfactual** (no migration, 100 % stay in Thena):
  - $180k × 18 % × 7/365 = **$622/wk**.
- **Migration edge: $187/wk = 30 % uplift on epoch-N+1 yield.**
- Migration cost: $180k × 60 % × 35 bps = $378 one-off → recouped in
  exactly **2 epochs** of edge.

## Trade-off observation
- The migration only pays off if the regime persists for ≥ 2 epochs.
- If Thena vote weights bounce back the next Thursday, the migration was
  wasted gas + slippage.
- Optimal threshold (MIGRATION_THRESHOLD_BPS) depends on expected
  vote-weight stickiness: 800 bps assumes ≥ 2-epoch persistence.

## $/THE and $/CAKE quantification
- Epoch N: emission collected: 5 178 THE @ $0.30 = **$1 553**.
- Epoch N+1 Thena: 830 THE = $249. PCS: 233 CAKE = $560.
- Realized blended $/emission-token: $0.30/THE, $2.40/CAKE.
- The strategy doesn't change token economics — only allocation.

## Risks not modelled
- **Whipsaw**: vote weights flipping every epoch erodes migration edge
  to less than gas cost.
- **PCS unstaking lock**: MasterChefV2 may have a 1-block delay; if Thena
  rate-write and our migration race, we lose 1 epoch of Thena yield with
  no PCS yield to compensate.
- **Vote-buy attack**: a competitor can vote-buy to deliberately swing
  Thena weight knowing we'll migrate, then capture our exit slippage.

## TODO
- Implement on-chain rate reader: `IThenaGauge(g).rewardRate(THE)` BEFORE
  and AFTER each Thursday `distribute()`.
- Hook PCS MasterChefV2.poolInfo(pid).allocPoint for the PCS side.
- Add hysteresis: only re-migrate if delta > MIGRATION_THRESHOLD + 200 bps
  to avoid whipsaw.
- Test multi-epoch persistence: simulate 4-week windows with realistic
  Thena vote drift.
