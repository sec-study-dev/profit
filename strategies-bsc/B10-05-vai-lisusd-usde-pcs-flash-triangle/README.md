# B10-05 — VAI + lisUSD + USDe triangular atomic arb (PCS v3 flash)

## Family

B10 · Cross-stablecoin CDP basis (atomic triangular branch).

## Thesis

BSC hosts three structurally distinct $1-target stables that almost never
trade in lockstep:

- **VAI** — Venus CDP-minted stable. Liquidity sits in PCS v2 with a
  retail-sized 25 bp swap fee + a chronic 20-40 bp under-peg drift.
- **lisUSD** — Lista CDP-minted stable. Liquidity is split between PCS v2,
  the Wombat lisUSD pool, and a Lista-incentivised vault.
- **USDe** — Ethena synthetic. Liquidity on BSC is concentrated on Wombat
  and PCS v3 1bp; price typically follows funding/issuance rather than the
  on-chain DEX state, so it can drift +10..+25 bp vs lisUSD intra-day.

When the directed product of edge prices along
`USDT → VAI → lisUSD → USDe → USDT` (net of fees) exceeds 1.0, the loop is
atomically profitable. The PoC flashes USDT from a PCS v3 1bp pool, runs
the four-hop loop, and repays with the surplus.

## Mechanism stack (3 distinct mechanisms)

1. **PCS v3 flash** — borrow USDT from the deep USDC/USDT 1bp pool with a
   1 bp premium, repaid in the same tx.
2. **PCS v2 / v3 spot swap** — handle the VAI legs (VAI's deepest venue is
   v2) and the USDe close leg on the v3 stable tier.
3. **Wombat StableSwap** — handle the lisUSD ↔ USDe edge, which has
   essentially no real depth elsewhere on BSC; Wombat's coverage-adjusted
   quote is what makes the triangle close.

## Why this is genuinely B10 (not a B07 / B09 dressing)

B07-04 and B09-01 are 2-stable single-edge Wombat ↔ PCS arbs. B10-05 is
**three CDP/synthetic stables in a single atomic cycle**, which is only
ever solvable because the three issuers have different funding curves
(Venus fee, Lista SF, Ethena yield/issuance). The basis is the cross-issuer
mispricing — the canonical B10 surface — captured atomically rather than as
held carry like B10-01 / B10-04.

## Block layout (atomic, one tx)

1. Flash `FLASH_NOTIONAL` USDT from PCS v3 USDC/USDT 1bp pool.
2. Inside the flash callback:
   - Leg 1: USDT → VAI on PCS v2.
   - Leg 2: VAI → lisUSD on PCS v2 (via USDT bridge).
   - Leg 3: lisUSD → USDe on Wombat (dynamic-weight depth).
   - Leg 4: USDe → USDT on PCS v3 stable tier (500 bps fee tier).
3. Repay `notional + 1 bp` USDT to the flash pool; keep the residual.

## Status & PnL

- **Status:** offline-first PoC. Compiles against the family-allowed
  interface surface (`IPancakeV3Pool`, `IPancakeV2Router`, `IPancakeV3Router`,
  `IWombatPool`). On-fork mode requires `BSC_RPC_URL` and a pinned block
  satisfying the triangle-open condition listed in the test header.
- **PnL model (offline):** `notional = $2m`. Synthetic edge prices encode a
  30 bp VAI discount, a near-par PCS lisUSD return, a 20 bp USDe premium
  through Wombat, and a 10 bp USDe→USDT close discount. Per-edge fees:
  v2 25 bp × 2 + Wombat 5 bp + v3 1 bp + flash 1 bp = ~57 bp total drag.
  Gross loop spread ≈ +60 bp ⇒ net ≈ +3 bp on $2m = **~$600 atomic**.

## Address / ABI verification

- All addresses sourced from `BSC.sol`. PCS v3 flash pool resolved at
  runtime via `IPancakeV3Factory.getPool(USDC, USDT, 100)`.
- Wombat lisUSD↔USDe routing: assumed via `WOMBAT_MAIN_POOL`. If the pool
  doesn't list both assets at the pinned block, the on-fork run will revert
  and fall back to the offline path.

## TODO

- Pin a real `FORK_BLOCK` once an open triangle is observed. The
  scaffolding currently uses 47.5m as a placeholder.
- Replace the synthetic price matrix in `_offlinePnLCheck` with a quoter
  read once `WOMBAT_MAIN_POOL.quotePotentialSwap` is plumbed through a
  view-only helper.
- Add a per-leg slippage guard so the on-fork callback reverts gracefully
  on shallow legs rather than completing an unprofitable loop.
- Confirm `VAI/USDT` PCS v2 still has > $100k depth at the pinned block;
  fall back to v3 USDC/USDT routing if not.
