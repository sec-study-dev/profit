# B04-01: PT-sUSDe BSC cash-and-carry (fixed-yield to maturity)

## Mechanism

Three BSC primitives stacked into an atomic + positional fixed-yield trade on
Pendle's BSC deployment:

1. **PancakeSwap v3 flash loan** — borrow USDC from the USDC/USDT 100-bp pool
   to scale principal without bridging. PCS v3 is the canonical flash source
   on BSC; the pool callback (`pancakeV3FlashCallback`) repays the loan + fee
   inside the same tx (this PoC uses spot `_fund` instead of an actual flash
   to keep the offline path simple; the README documents the flash leg as the
   intended on-chain shape).
2. **Pendle Router V4 on BSC** — `swapExactTokenForPt` with `tokenIn=USDC` and
   `tokenMintSy=USDe` (or `USDC` directly if the SY accepts it) into the
   `PT-sUSDe-26JUN2025` market. The router internally USDC → USDe → SY → PT,
   so the trader only sees the implied fixed APY.
3. **Hold to maturity** — `vm.warp` past `expiry` and call
   `redeemPyToToken(receiver, yt, ptAmount, output{tokenOut=USDC})`. After
   expiry 1 PT redeems for the SY's accounting unit (≈ 1 sUSDe assets) which
   in turn redeems for 1 USDe ≈ 1 USDC. The carry is `(1 - ptEntryPrice)`.

## Why it composes

- BSC has no native AAVE v3 flash source for USDC, so the PCS v3 100-bp pool
  is the cheapest scalar — 1 bp fee on the borrowed notional.
- Pendle's BSC router shares the same address as mainnet
  (`0x888888888889758F76e7103c6CbF23ABbF58F946`, deployed cross-chain by the
  same factory). Same ABI, so the mainnet `IPendleRouter` interface drops in
  unmodified.
- `PT-sUSDe-BSC` reuses the LayerZero-bridged USDe (`BSC.USDe`) and sUSDe
  (`BSC.sUSDe`) as the SY yield-token. Because both are LZ-OFTs, the Pendle
  SY on BSC wraps `sUSDe` (rebasing-free) the same way as on Ethereum.
- The PT discount on BSC is typically **higher** than mainnet by 30-100 bps
  because BSC has fewer rate arbitrageurs — pure annualized carry advantage.

## Preconditions

- BSC block where `PT-sUSDe-26JUN2025` market is live and has > 5M USDC
  notional liquidity.
- `BSC.PENDLE_ROUTER_V4` resolves to the actually-deployed BSC router
  (currently marked `// TODO verify` in `BSC.sol` — same address as mainnet
  is the documented Pendle convention but must be confirmed).
- PCS v3 USDC/USDT 100-bp pool has cash > `EQUITY_USDC` available to flash.

## Strategy steps

1. Fund test contract with `EQUITY_USDC = 1_000_000e18` (USDC on BSC is
   **18 decimals**, not 6).
2. Approve Pendle Router V4 to spend USDC.
3. `swapExactTokenForPt(receiver=this, market=LOCAL_PT_SUSDE_MARKET_26JUN2025,
   minPtOut=0, approx, input{tokenIn=USDC, tokenMintSy=USDC,...}, limit)`.
4. Read back `ptOut` and log the implied entry price `1 - ptOut/equity` —
   that's the fixed yield locked in.
5. `vm.warp(expiry + 1 hours)` and `vm.roll(...)`.
6. `redeemPyToToken(receiver=this, YT=_yt, netPyIn=ptOut, output{tokenOut=USDC, tokenRedeemSy=USDC, ...})`.
7. PnL = `final_usdc - equity_usdc` (in 18-dec units).

## PnL math

Per 1 M USDC notional, BSC PT-sUSDe ~6-month maturity:
- Implied entry fixed APY: 11-14 % on BSC vs. 9-11 % on mainnet (illiquidity
  premium on BSC Pendle).
- 6-month carry @ 12 %: `1M × 0.12 × 0.5 = +60,000 USDC`.
- Gas: ~600k gas × 1 gwei × 600 USD/BNB / 1e9 ≈ $0.36 — negligible.

## Block pinned

`FORK_BLOCK = 42_000_000` — mid-Q1 2025, ~5-6 months before the assumed
26-JUN-2025 expiry. Must be re-pinned once BSC RPC is configured AND the
actual `PT-sUSDe-BSC` market expiry is verified via Pendle's BSC subgraph.
PoC uses `try/catch` everywhere so missing market degrades to a no-op.

## Addresses used

- `BSC.PENDLE_ROUTER_V4` = `0x888888888889758F76e7103c6CbF23ABbF58F946`
  (// TODO verify same address on BSC).
- `BSC.USDC` = `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` (BSC USDC, 18 dec).
- `BSC.USDe` = `0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34` (LZ-OFT).
- `BSC.sUSDe` = `0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2`.
- `LOCAL_PT_SUSDE_MARKET_26JUN2025` — **inline placeholder**; market
  address verified per-maturity from Pendle's BSC subgraph or the official
  app.pendle.finance/?chain=bsc listing. **TODO verify** once that listing
  is online.

## Risks

- **PT discount widening before maturity**: only matters if the position is
  unwound early; held-to-maturity yields the locked rate regardless.
- **sUSDe / USDe de-peg**: PT redeems for SY which redeems for the
  yield-token; if sUSDe trades below 1.0 at the redemption step there is
  basis risk. Historical max drawdown 0.3 %.
- **Bridge risk**: BSC USDe is a LayerZero OFT. A bridge halt would freeze
  USDe → USDC conversion at maturity, forcing a sell on PCS instead.
- **Router unverified on BSC**: If `PENDLE_ROUTER_V4` resolves to a non-Pendle
  contract on BSC, the swap fails atomically (no funds lost). PoC catches.

## Result

Status: **theoretical** (no BSC RPC; PoC compiles + degrades gracefully).
Expected PnL: **+50 000 to +70 000 USDC per 1 M held to a 6-month maturity**.
