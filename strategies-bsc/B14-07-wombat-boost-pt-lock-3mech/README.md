# B14-07: Wombat MasterChef LP + veWOM boost + Pendle PT lock — 3-mech

## Mechanism (3-mech)
The Wombat USDT pool LP earns three independent yield streams once
veWOM-boosted and partially Pendle-locked:

1. **Wombat LP fees + base WOM emission**. The USDT pool pays a small
   swap-fee APR (~0.8 %) plus base WOM token emission (~3.5 %).
2. **veWOM boost**. Locking WOM into veWOM (4-year peak) lifts the
   *boostMultiplier* on the LP's WOM emission stream up to ~2.0×,
   turning a 3.5 % base into ~7 %.
3. **Pendle PT-WOMlp lock**. Pendle's PT-WOMlp market lets you sell
   the LP's *yield stream as YT* and pocket the discounted PT, locking
   the boosted-rate proxy (~8.5 %) over the maturity. We allocate
   20 % of principal to PT and 80 % to the boosted LP — the PT is a
   convexity hedge against WOM-emission cuts.

Three mechanisms — base AMM fees, governance-token boost lever, and
Pendle term lock — touch entirely different reflexive surfaces so
they aggregate without correlation.

## Why it composes
- Wombat is the deepest BSC stableswap (>$200M TVL) so the USDT pool
  absorbs $100k+ deposits without skew penalty.
- veWOM is non-transferable but the *boost* is reflected in subsequent
  `multiClaim` calls — no extra contract interaction per claim.
- PT-WOMlp on Pendle BSC has been live since Pendle's BSC launch
  (cf. F07 family on mainnet for the comparable structure).

## Preconditions
- BSC block where Wombat MasterChef V3 has the USDT gauge active and
  veWOM peak boost ≥ 1.8×.
- Pendle PT-WOMlp market live with ≥ $1M TVL.
- WOM price > $0.20 (so the WOM-denominated emission converts to ≥
  3 % stable APR at the modelled USDT principal).
- The strategy assumes the user **already holds the WOM that will be
  locked into veWOM** — the PoC pre-funds a 1000 WOM stash via
  `_fund` to simulate this. Acquisition cost of the WOM is excluded
  from the 60-day horizon and treated as a sunk capex (the
  `VEWOM_LOCK_DRAG_BPS = 15 bp` line item amortises only the lock
  transaction + opportunity cost over the 60-day window).

## Strategy steps (100k USDT, 60-day hold)
1. `_fund` 100k USDT.
2. Split 80/20: 80k → Wombat USDT LP (`shouldStake = true`); 20k →
   Pendle PT-WOMlp.
3. Lock pre-existing 1000 WOM into veWOM at 4-year peak → 2.0× boost.
4. Hold 60 days; claim WOM via MasterChef `multiClaim`.
5. PT matures or marks closer to par as time passes; PnL recognises
   accrued discount.
6. PnL = LP carry (fees + boosted WOM) + PT lock carry − PT entry
   drag − veWOM lock drag.

## PnL math (100k USDT principal, 60-day horizon)
Split: `lpLeg = 80k`, `ptLeg = 20k`.

- **Leg 1+2 — LP boosted**:
  - LP APY = `0.80 % swap-fee + (3.50 % × 2.00)= 0.80 + 7.00 = 7.80 %`.
  - 60d on 80k: `7.80 % × 60/365 × 80k = +1,025 USD`.
- **Leg 3 — PT-WOMlp**:
  - 8.50 % implied APR × 60/365 × 20k = `+279 USD`.
- **Drags**:
  - PT entry on 20k @ 40 bp = `-80 USD`.
  - veWOM lock amortised on 80k @ 15 bp = `-120 USD`.

Total: `+1,025 + 279 − 80 − 120 = +1,104 USD ≈ +1.10 %` on 100k over
60 days (`~6.7 %` annualised).

Compare to **plain unboosted Wombat LP** (`0.80 % + 3.50 % = 4.30 %`
× 60/365 × 100k = `+707 USD`): the stack adds **+397 USD or +56 bp /
60d** which is the value-add of (a) veWOM boost lever and (b) Pendle
PT term lock combined.

Gas: ~2.5M gas × 1 gwei × $600/BNB ≈ `$1.5`.

## Block pinned
**42_500_000** (late-2024). Re-pin once Wombat MasterChef V3 + Pendle
PT-WOMlp BSC market are verified live.

## Addresses used
- `0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0` — Wombat Main Pool.
- `0xAD6742A35fB341A9Cc6ad674738Dd8da98b94Fb1` — WOM token.
- `0x888888888889758F76e7103c6CbF23ABbF58F946` — Pendle Router V4.
- `LOCAL_WOMBAT_MASTERCHEF` (`0x...B14070`) — placeholder.
- `LOCAL_VEWOM` (`0x...B14071`) — placeholder.
- `LOCAL_PT_WOMLP_MARKET` / `LOCAL_PT_WOMLP` — placeholders.

## Risks
- **WOM price drawdown**: a 50% WOM crash halves the boosted WOM-leg
  carry, bringing LP APY from 7.8% down to ~4.3%. Strategy is
  WOM-price-elastic on the boost leg.
- **veWOM lock illiquidity**: 4-year lock is highly path-dependent;
  early unlock not possible. Treat the WOM stash as effectively
  sunk capital. Mitigated by sizing veWOM lock to multi-strategy
  amortisation (re-used across B14-07, B09-06, etc.).
- **Wombat pool depeg**: USDT main pool guesses peg-deviation across
  USDT/USDC/BUSD/lisUSD; a stable depeg widens the LP haircut. The
  60-day horizon is long enough to absorb 1-2 brief depeg episodes.
- **Pendle PT discount widening**: PT-WOMlp marking down 2 %
  mid-life costs the PT leg `-400 USD`. Hold-to-maturity converges
  to par.
- **MasterChef migration**: Wombat has historically migrated
  MasterChef versions; the PoC `try/catch`'s `multiClaim`.

## Result
Status: **theoretical** — BSC RPC + Pendle PT-WOMlp BSC market +
Wombat MasterChef V3 USDT gauge not yet verified. Expected PnL:
**+1.10 % over 60 days on 100k USDT principal**, +56 bp alpha vs.
plain unboosted LP, decomposed as ~93 % from boosted LP and ~25 %
from PT lock minus ~18 % drag.

## TODO
- Verify Wombat MasterChef V3 address and USDT pool ID.
- Verify veWOM lock contract & confirm `createLock` selector.
- Verify Pendle PT-WOMlp BSC market via Pendle subgraph.
- Externalise the WOM-acquisition cost into the PnL when running a
  fresh deployment (i.e. amortise full WOM purchase across N
  strategies, not just B14-07).
