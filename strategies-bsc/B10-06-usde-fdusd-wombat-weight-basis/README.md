# B10-06 — USDe + FDUSD + Wombat dynamic-weight basis

## Family

B10 · Cross-stablecoin CDP basis (LP / dynamic-weight branch).

## Thesis

Wombat's StableSwap invariant prices a swap according to the destination
asset's *coverage ratio*: corrective-direction swaps (taking from the
over-allocated asset, leaving the under-allocated asset) earn a
several-bp bonus over par. The bonus is structurally larger than the PCS
StableSwap haircut because Wombat's curve uses a dynamic-A scaler that is
asymmetric on each side of the coverage axis.

BSC has two stables whose flows naturally skew Wombat in opposite
directions:

- **FDUSD** — Binance promo + perp settlement flow chronically over-allocates
  it (coverage > 1.05 several times per week).
- **USDe** — Ethena redemptions on the BSC OFT chronically under-allocate
  it (coverage < 0.95 after big mint/redeem batches).

B10-06 captures the resulting basis as **held LP carry over a bounded
session window** rather than as a single-tx atomic arb (the way B07-04 does
it). We deposit on the heavy side (FDUSD), wait for organic counter-flow
to rebalance the pool, withdraw on the light side (USDe), then close back
to FDUSD through PCS StableSwap (or Ethena redeem as a fallback if the PCS
exit is wider than Ethena's 5 bp mint fee).

## Mechanism stack (3 distinct mechanisms)

1. **Wombat StableSwap LP** — `deposit(FDUSD)` + `withdraw(USDe)`. The
   dynamic-weight bonus accrues at withdrawal time to the LP that entered
   the heavy side.
2. **PCS StableSwap** — `exchange()` on the 3-pool, used to close
   `USDe → USDT → FDUSD` after the Wombat leg.
3. **Ethena USDe direct redeem** — held in reserve as the fallback exit
   when PCS StableSwap depth is shallow at the exit moment. Currently a
   placeholder helper; on-chain selector pending the BSC-side OFT ABI.

## Why this is genuinely B10 (not B09 dynamic-weight)

B09-02 captures the Wombat weight skew via a *flash + swap* (atomic, one
block). B10-06 captures the same surface as **held LP carry across a
session window** so it composes with Ethena USDe's mint/redeem
mechanism — a cross-stable-issuer leg that B09 never touches.

## Block layout (bounded session window)

1. `t = 0` — supply NOTIONAL FDUSD to `WOMBAT_MAIN_POOL.deposit(FDUSD, ...)`.
2. `t = 0..HOLD_HOURS` — pool absorbs organic counter-flow; LP value
   inflates by the coverage bonus.
3. `t = HOLD_HOURS` — `withdraw(USDe, lp)`; receive USDe on the now-light
   side at a per-LP rate higher than the entry rate.
4. Close: `USDe → USDT` via PCS StableSwap; `USDT → FDUSD` via PCS or
   Wombat. (Both close legs are stable-stable, costing ~4 bp each.)
5. PnL = (coverage bonus + LP carry) − (deposit haircut + withdraw haircut
   + 2× close-leg fees).

## Status & PnL

- **Status:** offline-first PoC. Compiles against the family-allowed
  interface surface (`IWombatPool`, `IPancakeStableRouter`). On-fork mode
  requires `BSC_RPC_URL` and a pinned block where Wombat FDUSD coverage
  > 1.08 and USDe coverage < 0.92.
- **PnL model:** `notional = $1.5m`, `hold = 36h`. Numbers used in offline:
  - Deposit haircut: 3 bp.
  - Coverage bonus (FDUSD heavy → light USDe): +28 bp.
  - LP carry over 36h at 4.5 % APR: +1.85 bp.
  - Withdraw haircut: 3 bp.
  - Close legs: 2 × 4 bp = 8 bp.
  - Net: ~+15.85 bp ≈ **$2,378 on $1.5m**.

## Address / ABI verification

- `BSC.WOMBAT_MAIN_POOL` and `BSC.PCS_STABLE_ROUTER` sourced from `BSC.sol`.
  Both currently carry `// TODO verify` markers in BSC.sol; the on-fork
  path will revert at deposit time if the pool doesn't list FDUSD or USDe.
- Ethena redeem ABI is not pinned on BSC; placeholder helper used. See TODO.

## TODO

- Pin a real `FORK_BLOCK` once a coverage-imbalance episode is observed.
- Replace the synthetic `COVERAGE_BONUS_BPS` and `WOMBAT_LP_APR_BPS` with
  on-fork reads (Wombat does not currently expose either as a
  view-callable; would need to instrument deposit + withdraw quotes).
- Confirm PCS StableSwap coin-index ordering for the FDUSD-pool; the
  `(1, 2)` USDT/USDC choice here is the 3-pool default and may not be
  the same pool that hosts FDUSD.
- Wire up the Ethena redeem fallback once the BSC OFT adapter exposes a
  burn-and-bridge selector.
- Add a re-deposit branch: if the coverage gap *widens* during the hold,
  we should top up instead of withdrawing.
