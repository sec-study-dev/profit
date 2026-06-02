# B11-03: asBNB → Pendle PT/YT split — points decoupling

## Mechanism
Pendle's principal/yield split lets us cleanly separate the two yield streams
embedded in asBNB:

- **PT-asBNB** → the BNB-denominated principal claim. Trades at a discount;
  redeems 1:1 to asBNB at expiry. Holding PT alone = fixed-rate BNB carry.
- **YT-asBNB** → the floating yield strip *plus* Astherus points stream
  (assuming Pendle's standard "points" SY adapter). Holding YT = pure points
  long with capped principal at risk.

This PoC routes 100 BNB principal through Astherus → asBNB → SY-asBNB →
(PT, YT) split. Holding both halves jointly is *economically identical* to
holding asBNB, so this position is a synthetic version of B11-01 with no
on-chain leverage — useful when:

- vBNB borrow APR is elevated (B11-01 / B11-02 carry compresses)
- the user wants explicit YT-points exposure without recursive lending
- the user later wants to **sell YT** to lock fixed yield, or **buy more
  YT** to amplify points exposure

The strategy is the foundation for those follow-on trades — by minting both
sides this PoC demonstrates the Pendle entry primitive on asBNB.

## Why it composes
- Astherus asBNB is a vanilla ERC-20 with an ERC-4626-style exchange rate,
  so Pendle's SY adapter for "rebasing-like" LSTs slots in directly.
- Pendle's points-streaming SY variants (used for eETH, ezETH, rsETH on
  mainnet) explicitly *route* the underlying protocol's points to YT
  holders. Asssuming Pendle BSC ships the same SY family for asBNB, we
  get points decoupling for free.
- PT + YT held jointly = asBNB, so there is no synthetic-vs-spot basis
  risk if held to maturity (modulo Pendle protocol risk).

## Preconditions
- Pendle Router V4 deployed on BSC at `BSC.PENDLE_ROUTER_V4` (currently
  mirrors the mainnet address; **TODO verify**).
- SY-asBNB / PT-asBNB / YT-asBNB markets exist at the pinned block. None
  of these have verified addresses yet; PoC uses `LOCAL_*` placeholders
  guarded by `_hasCode` checks.
- asBNB itself is live (Astherus addresses TODO-verify).

## Strategy steps
1. Mint 100 BNB → ~97.56 asBNB via Astherus StakeManager.
2. `PendleRouterV4.mintSyFromToken(BSC.asBNB, SY-asBNB, ...)` → SY-asBNB.
3. `PendleRouterV4.mintPyFromSy(SY-asBNB, YT-asBNB, ...)` → equal PT+YT.
4. Hold to expiry (90 days assumed):
   - PT pulls toward 1.0 asBNB.
   - YT bleeds yield + accumulates Astherus point claims.
5. At maturity:
   - PT redeems 1:1 to asBNB.
   - YT has paid out the cumulative stake yield + points (modelled here as
     residual = 0 since claimable rewards already accrued to the wallet).

## PnL math
Assumptions at pinned block, 90-day expiry:
- t=0 asBNB/BNB rate: 1.025
- BNB validator APY: 3.8 % → 90d drift = 1.025 × 1.00937 = 1.0346
- 100 BNB → 97.56 asBNB at entry → 100.93 BNB at maturity = **+0.93 BNB**
  pure stake yield (PT leg)
- Astherus points: 1.0 % APY × 90/365 = 0.247 % of NAV → **+0.247 BNB**
  USD-equivalent (YT leg, **assumption**)
- **Total: +1.18 BNB per 100 BNB over 90 days** with zero borrow risk.

### Variants this PoC bootstraps
Once the (PT, YT) pair is minted, three follow-on trades become available:
1. **Sell YT** on the Pendle AMM → lock fixed PT carry ≈ 5.0 % APY (the
   "cash-and-carry" leg, analogous to B04-01).
2. **Buy more YT** on the AMM with the YT-sale proceeds → long points at
   ~20× implied leverage (`YT price ≈ 5 % of asBNB` → 20× points exposure
   per dollar at risk).
3. **LP into the Pendle PT/SY pool** → earn AMM fees + extra PENDLE/CAKE
   incentives.

The base PoC only mints; the follow-on trades are documented but not
materialised.

## Block pinned
**45,500,000** — TODO re-pin. All Pendle-asBNB market addresses (SY, PT, YT)
need verification; PoC `_hasCode`-gates them and falls through to a
documented-rates simulation otherwise.

## Addresses used
- `BSC.ASTHERUS_STAKE_MANAGER`, `BSC.asBNB` — **TODO verify** in BSC.sol.
- `BSC.PENDLE_ROUTER_V4` — **TODO verify** (reuses mainnet address).
- `LOCAL_SY_ASBNB`, `LOCAL_PT_ASBNB`, `LOCAL_YT_ASBNB` — placeholders, not
  yet listed in `BSC.sol`. Pinned inline in the PoC.

## Risks
- **Address availability**: 6 of the 7 addresses needed are flagged
  TODO-verify or are local placeholders. Without the Pendle SY-asBNB
  adapter the strategy reduces to "buy and hold asBNB", which is fine but
  not the point.
- **Points-stream adapter**: Pendle's SY contract must actually *forward*
  Astherus points to YT holders. If the adapter uses a vanilla
  IStandardizedYield (no points pass-through), the YT leg degenerates to
  just the stake-yield strip and the points value is lost on the floor.
- **Pendle AMM thin liquidity** on BSC: minting PT/YT is fine, but
  subsequent trades (the cash-and-carry variant) may suffer 20-50 bp
  slippage on the SY/PT AMM.
- **Expiry timing risk**: if held past expiry on the YT side without
  claiming, residual yield can be reclaimed but at a gas cost premium.
- **Maturity convergence is assumed**, not enforced. If Pendle reprices PT
  at maturity using a stale asBNB rate, PT may settle at 99.8 % rather
  than 100 % of the underlying.

## Result
Status: **theoretical** (offline-first; PT/YT addresses are placeholders).
Expected PnL: **+1.0–1.4 BNB per 100 BNB over 90 days**, with the points
half subject to a 1 % APY assumption. With points at zero the strategy
still yields +0.93 BNB pure stake carry.
