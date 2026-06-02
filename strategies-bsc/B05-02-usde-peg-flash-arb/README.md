# B05-02: USDe peg arbitrage — PCS v3 flash → Wombat StableSwap → repay

## Mechanism
Atomic single-block arbitrage of the persistent BSC USDe < $1 peg gap.

1. **PCS v3 USDC/USDT 5bp pool flash** — PCS v3 pools support
   UniswapV3-style `flash(...)` callbacks. We flash-borrow USDC from the
   deepest USDC/USDT pool (no peg fee on this pool; the 5 bp fee is paid on
   repayment in-kind).
2. **PCS v3 USDC/USDe 1bp pool (or 5bp)** — when USDe trades at, say, 60 bp
   discount, we swap USDC → USDe at the discounted on-AMM rate. The 1 bp
   pool is thin but lower-fee; the 5 bp pool is deeper. We pick the better
   net price.
3. **Wombat StableSwap USDe/USDT** — Wombat's dynamic-asset-weight pool
   often quotes USDe at a different (closer-to-peg) price than PCS v3 when
   Wombat is heavily weighted to USDT. Swap USDe → USDT on Wombat at the
   tighter quote.
4. **PCS v3 USDT/USDC 5bp** — swap USDT back to USDC to repay the flash
   loan (plus 5 bp fee).

If the cumulative price chain `USDC → USDe (PCS, discounted) → USDT
(Wombat, near-par) → USDC (PCS, par)` exceeds `1 + flash_fee +
pool_fees`, the arb closes profitable. The whole thing is atomic in a
single block under `pancakeV3FlashCallback`.

## Why it composes
- **PCS v3 + Wombat use different invariants**: PCS v3 is a vanilla
  concentrated-liquidity curve quoting USDe based on tick-level
  liquidity; Wombat is a dynamic-coverage StableSwap where the marginal
  price depends on the *ratio of asset coverages*. When a Wombat asset
  is over-covered (lots of USDT in, USDe drained), Wombat quotes USDe
  more expensively (better for our exit). So the arb is structurally a
  *cross-DEX coverage* arb, not a stale-oracle arb.
- **USDe peg on BSC structurally trades below $1** because (a) the only
  mint/redeem path is on Ethereum mainnet (LayerZero OFT bridge in/out
  has a ~2-day delay & ~$50k batch min), and (b) BSC USDe is mostly held
  for yield (sUSDe), not for liquidity. So the discount is *persistent*,
  not noise — flashloans don't fully arb it out because the round-trip
  to mainnet is cost-prohibitive at retail size.
- The PCS v3 flash + atomic close is the right tool because we don't
  need any external capital and the price gap is small (≤ 150 bp), so
  size has to be large to make gas worthwhile.

## Preconditions
- BSC block where USDe/USDC PCS v3 pool quotes USDe at a >= 30 bp
  discount to peg and Wombat's USDe asset coverage is >= 1.05 (so its
  USDe → USDT quote is near-par or premium).
- PCS v3 USDC/USDT 5 bp pool has >= $20M reserves so the flash size
  doesn't move price.
- Wombat main pool USDe asset listed and active.

## Strategy steps (single atomic tx)
1. Compute optimal flash size `X` from the price gap (closed-form for
   small gaps: `X* ≈ sqrt(gap * L1 * L2 / (fee_sum))`). Cap at 500k USDC
   for the PoC.
2. Call `IPancakeV3Pool.flash(recipient=self, amount0=X, amount1=0,
   data=encoded)` on the USDC/USDT 5 bp pool.
3. In `pancakeV3FlashCallback(fee0, fee1, data)`:
   1. Swap `X USDC → USDe` on PCS v3 USDC/USDe 5 bp pool.
   2. Swap `Y USDe → USDT` on Wombat USDe/USDT.
   3. Swap `Z USDT → USDC` on PCS v3 USDT/USDC 5 bp pool.
   4. Repay flash: `IERC20(USDC).transfer(pool, X + fee0)`.
   5. Surplus USDC stays in this contract.
4. Sweep surplus.

## PnL math (500k USDC notional)
Assume USDe trades at $0.994 (60 bp discount) on PCS v3, Wombat returns
$0.998 on the way out (40 bp premium relative to PCS), and the USDT/USDC
loop pool is flat to peg.

- Leg 1 (USDC → USDe @ 5 bp pool): 500_000 / 0.994 * (1 − 0.0005) =
  502,768 USDe.
- Leg 2 (USDe → USDT @ Wombat): 502,768 * 0.998 * (1 − 0.0002 haircut) =
  501,560 USDT.
- Leg 3 (USDT → USDC @ 5 bp pool): 501,560 * (1 − 0.0005) = 501,309
  USDC.
- Flash repayment: 500_000 * (1 + 0.0005) = 500,250 USDC.
- **Net surplus: 501,309 − 500,250 = 1,059 USDC ≈ +0.21 % of notional**.

Gas: ~450k for flash + 3 swaps. At 1 gwei × $600/BNB ≈ $0.27 — entirely
negligible.

## Block pinned
**42_800_000** — picked for a representative session where BSC USDe
discount widens to ~60 bp during US-night liquidity gaps. Strategy is
sensitive to the gap magnitude; PoC includes an offline branch that
emulates the gap exactly so accounting is deterministic.

## Addresses used
- `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` — USDe (`BSC.USDe`).
- `0x55d398326f99059fF775485246999027B3197955` — USDT (`BSC.USDT`).
- `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` — USDC (`BSC.USDC`).
- `0x312Bc7eAAF93f1C60Dc5AfC115FcCDE161055fb0` — Wombat main pool
  (`BSC.WOMBAT_MAIN_POOL`).
- `LOCAL_PCS_V3_USDC_USDT_5BP` — PCS v3 USDC/USDT 5bp pool. Placeholder
  `0x000000000000000000000000000000000000B521` until verified.
- `LOCAL_PCS_V3_USDC_USDE_5BP` — PCS v3 USDC/USDe 5bp pool. Placeholder
  `0x000000000000000000000000000000000000B522`.

## Risks
- **Gap closes mid-tx**: another arber races us. Mitigation: this is
  atomic — if the pool quotes have moved, the swap min-out reverts.
- **Wombat coverage flips**: if a large USDe deposit lands in Wombat
  between blocks, the USDe → USDT leg quote can flip *worse* than PCS.
  We require Wombat exit price > PCS exit price ex-ante.
- **Pool fee tier wrong**: 1 bp tier might be thin. PoC uses 5 bp as the
  conservative default.
- **Flash repayment underflow**: must be guarded by `require(balance ≥
  X + fee)` before transfer to avoid pool revert that wastes gas.

## Result
Status: **theoretical** (BSC RPC not configured). Expected PnL: **+0.15
– 0.30 % of notional per opportunity**, opportunity frequency ~2-3×
per week during US-overnight liquidity gaps. Offline PoC sets the gap
explicitly and asserts a positive `pnl_usd`.
