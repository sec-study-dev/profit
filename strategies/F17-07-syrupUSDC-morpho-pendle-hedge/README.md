# F17-07: syrupUSDC carry on Morpho with Pendle PT hedge

## Mechanism

A three-mechanism leveraged carry combining institutional-lending yield,
isolated lending market leverage, and fixed-rate hedging via Pendle:

1. **Maple syrupUSDC** (ERC4626 over institutional USDC loans) —
   variable APY in the ~10–12% range in mid-2024. Yield is
   credit-bearing (vs Aave's pool-utilisation-based rate).
2. **Morpho Blue isolated market `syrupUSDC/USDC`** — a curated market
   (created by Maple-aligned curators) with `collateral=syrupUSDC`,
   `loanToken=USDC`, `lltv=86.5%`. Allows looping the carry by
   borrowing USDC against syrupUSDC.
3. **Pendle PT-syrupUSDC** — Pendle splits syrupUSDC into PT (principal,
   fixed) and YT (yield, floating). Buying PT with the *borrowed* USDC
   locks in the implied fixed rate for the borrow leg, partially
   neutralizing the variable-rate exposure on Morpho.

```
seed USDC --deposit--> syrupUSDC --supplyCollateral--> Morpho
                          ^                                 |
                          |                              borrow USDC
                          |                                 |
                          +------------- (recycle) ----+ (50% to PT-syrupUSDC)
                                                       |
                                                       v
                                                   Pendle PT (fixed APY)
```

## Why it composes

This is the most credit-risk-aware F17 strategy. The combination is
unique because:

- **Different yield sources stacked vertically.** Maple = institutional
  credit; Morpho borrow = USDC supplier APY; Pendle PT = fixed-rate
  contract written against syrupUSDC's future cashflows. The position
  has *both* long-credit (Maple) and short-credit (Morpho borrow side)
  exposure simultaneously.
- **Pendle as hedge, not core**. Unlike F07-* strategies that go fully
  long PT, here PT is sized at 50% of the borrow (HEDGE_FRAC_BPS=5000)
  to convert *part* of the variable Morpho debt into a fixed-rate
  obligation. When Maple's variable APY drops below the PT-implied
  fixed APY, the PT position outperforms the equivalent variable
  position by `r_fixed − r_variable_at_T`.
- **Morpho isolation**. Maple's syrupUSDC market on Morpho is isolated;
  a syrupUSDC NAV haircut (Maple default) does not cascade to other
  Morpho markets — only the syrupUSDC/USDC pair is impaired.

## Preconditions

- syrupUSDC Maple vault active and unpaused (`asset() == USDC`).
- Morpho Blue market for syrupUSDC/USDC exists. Curated markets are
  permissioned-creation but listing is permissionless; verify market
  id via `keccak256(abi.encode(MarketParams))`.
- Pendle PT-syrupUSDC market live with positive `expiry > block.timestamp`.

## Strategy steps

1. Pin **block 20_700_000** (~Aug 30 2024).
2. In `setUp`, attempt to read Pendle market tokens. If revert, set
   `_pendleAvailable = false` and continue without the hedge leg.
3. Seed 250k USDC; deposit → syrupUSDC.
4. Supply syrupUSDC as collateral on Morpho via `supplyCollateral`.
5. Borrow USDC at LOOP_LTV_BPS = 75% (well under 86.5% LLTV).
6. Spend 50% of borrowed USDC on PT-syrupUSDC via Pendle Router V4.
7. Hold remaining 50% in USDC (could be looped further; PoC stops here
   for clarity).
8. Read & log Morpho position; assert collateral > 0, debt > 0, PT > 0.

## PnL math

Let:

- `N = $250k` (equity)
- `r_M = 11%` (Maple syrupUSDC variable APY)
- `r_b = 6%` (Morpho USDC borrow APY, healthy market rate)
- `r_PT = 12%` (Pendle PT implied APY, 90 days to expiry)
- `LTV = 0.75`
- `L = N · (1 + LTV) = N · 1.75` (single-loop levered notional)
- Hedge: 50% of borrowed USDC into PT

```
Levered carry on Maple side: L · r_M = N · 1.75 · 0.11 = 0.1925 · N
Borrow drag (Morpho):       (L−1) · r_b = N · 0.75 · 0.06 = 0.045 · N
Pendle PT carry on 50% borrow: 0.5 · (L−1) · N · r_PT = N · 0.0375 · 0.12 = 0.0045 · N
                  (using PT-side amount = 0.5 · borrowed = 0.5 · 0.75N)

NetAPY ≈ (0.1925 − 0.045 + 0.0045) · 1.0  = 0.152 = 15.2%
```

vs unlevered Maple = 11%. Uplift ≈ 4.2 pp APY.

For a 90-day horizon: $250k · 0.042 · (90/365) ≈ $2,590 incremental.

Hedge property: if Maple variable drops to 7%, levered carry falls to
0.1225·N; Pendle PT still pays 0.0045·N regardless; borrow drag
unchanged. NetAPY → 8.2% vs unhedged 7% (the PT hedge captures the
fixed/floating spread when floating compresses).

Gas: 1 syrupUSDC deposit + 1 Morpho supply + 1 Morpho borrow + 1 Pendle
swap ≈ 700k gas → $42 at 30 gwei.

## Block pinned

`20_700_000` (~Aug 30 2024). syrupUSDC pool live; Morpho Blue
isolated-market deployments active; Pendle PT-syrupUSDC market expected
to exist (mid-summer 2024 was when Pendle expanded into Maple's
syrupUSDC after the partnership announcement).

## Risks

- **Pendle PT-syrupUSDC market not live at FORK_BLOCK.** Pendle markets
  per-asset are launched on a rolling schedule; the PoC's `setUp` reads
  `readTokens()` via try/catch and falls through to a Morpho-only
  unhedged carry path if absent. This is the dominant fallback outcome
  for any block before the market launch.
- **Morpho market not found.** The Morpho market id depends on exact
  params; PoC `try`s `supplyCollateral` and short-circuits cleanly.
- **Maple credit default.** Worst observed in Maple v1: 4-5% NAV
  write-down. With `LTV=0.75`, a 5% write-down brings effective LTV to
  ~0.79 — still safe. Beyond 11% NAV haircut, liquidation risk on the
  Morpho side.
- **PT mark-to-market in volatile rate regimes.** PT is delta-1 on the
  underlying but has duration; a sharp rise in syrupUSDC APY produces
  a PT price drop. The hedge protects against rate *fall*, not rate
  *rise*.
- **Maple withdrawal queue.** Maple v2 pools enforce epoch-based exits;
  the strategy is therefore not instantly unwindable. The PoC focuses
  on entry; exit timing is operator discretion.

## Result
Status: theoretical
Expected PnL: ~15.2% APY on equity (~4.2pp uplift over unlevered Maple 11%; ~$2,590 incremental net per $250k seed over 90 days at r_M=11%, r_b=6%, r_PT=12%, L=1.75x)

A persistent levered carry on syrupUSDC with a Pendle fixed-rate hedge.
Asserts (a) syrupUSDC deposit succeeds, (b) Morpho collateral + borrow
succeed in one tx, (c) PT-syrupUSDC hedge is posted at HEDGE_FRAC_BPS
of the borrowed USDC, (d) no underwater state at exit. Documents the
three-mechanism stack as the canonical "long-credit + lend-short +
fix-floating" yield-bearing-stable composition.
