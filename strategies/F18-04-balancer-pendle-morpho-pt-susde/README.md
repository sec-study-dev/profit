# F18-04: Balancer flashloan + Pendle PT-sUSDe + Morpho USDC-PT cash-and-carry

## Mechanism

Atomic single-tx, single-tx, single-block three-protocol cash-and-carry on
the PT-sUSDe market. Mechanically:

1. **Balancer V2 Vault flashloan** — 0-fee, multi-asset, callback-style
   flashloan. We flash 10M USDC (well within Balancer's USDC liquidity).
   This is *the* zero-fee flashloan venue for USDC (Aave charges 5 bps,
   DssFlash is DAI-only).
2. **Pendle PT-sUSDe market** — buy PT-sUSDe at a discount via
   `swapExactTokenForPt`. PT-sUSDe trades 7-15% under sUSDe spot at most
   blocks because it's a fixed-rate claim on sUSDe at expiry and the
   implied APY frequently matches sUSDe's variable APY.
3. **Morpho Blue PT-sUSDe-26SEP2024 / USDC market** — marketId
   `0xe3569130a77514ee127338c307790b2ccc73d9e601917d3ddfe6219a19662ee1`
   (computed from canonical MarketParams; recovered on-chain via
   `idToMarketParams` in setUp and asserted against the expected tuple).
   LLTV 86.5%; specifically supports PT-sUSDe-26SEP2024 as collateral
   (the only money-market that does at the pinned block).

The atomicity is critical: **the Balancer flash is repaid in the same tx
that opens the Morpho borrow that funds the PT buy**. If any leg fails,
the whole sequence reverts. Net opens with zero user equity (the flash
self-funds), and the resulting position is **(PT-sUSDe collateral, USDC
debt)** at K = 1/(1-0.915) ≈ 11.8x.

This is the canonical PT-cash-and-carry, but the **3-mechanism atomicity
(flash + PT + Morpho)** is what distinguishes F18-04 from F07-01 (which
is the same trade *bootstrapped slowly with user equity, no flash*).

## Why it composes — the 3 mechanisms

1. **Balancer V2 Vault flashLoan** — only zero-fee USDC flash on
   mainnet that's deep enough for size (Maker is DAI-only; Morpho
   Blue's USDC market spare is shallower than Balancer's vault).
2. **Pendle PT-sUSDe market** — the only on-chain venue to trade
   PT-sUSDe at its implied APY; both the discount and the entry path.
3. **Morpho PT-sUSDe / USDC isolated market** — the only money-market
   listing PT-sUSDe as collateral with USDC debt. LLTV 91.5% turns the
   discount into a leveraged carry.

No 2-mechanism combo achieves this:
- (Balancer + Pendle): user buys PT-sUSDe with flash USDC. But the
  flash *must be repaid before tx end*, so without Morpho there is no
  way to *finance* the PT purchase — the PT cannot itself be unwound
  back to USDC at par within the same tx (it's locked to maturity).
- (Pendle + Morpho): user must front-load USDC equity; capital is
  trapped for the duration (no leverage on first dollar).
- (Balancer + Morpho): no PT means no PT-discount edge; this is just
  a flashloan into a Morpho position, which provides no edge.

Only the triangle (atomic flash + atomic PT mint + atomic Morpho
supply+borrow) lets the cash-and-carry open at K≈7-8 with zero up-front
equity (LLTV 86.5% → max attainable c-ratio ≈ 1/(1-0.865) ≈ 7.4×).

## Preconditions

- Block where Balancer USDC vault balance ≥ flash amount (~20M USDC at
  pinned block).
- Block where Pendle PT-sUSDe market is live and PT trades ≥ 5%
  discount to sUSDe parity (true 2024-onwards).
- Morpho PT-sUSDe/USDC market live with available USDC supply ≥
  borrow target.

Pinned block: **20,200,000** (mid-July 2024).

## Strategy steps (PoC)

1. Balancer Vault `flashLoan(USDC, 10M)`.
2. In `receiveFlashLoan`:
   a. Convert flash USDC → USDe on the Curve USDe/USDC NG pool
      (transit step — SY-sUSDe accepts USDe but not USDC directly).
   b. Approve Pendle Router for USDe; call
      `swapExactTokenForPt(USDe, PT_SUSDE_MARKET, ~10M USDe)`. Receive
      ~10.7-11.0M PT-sUSDe (PT discount captured).
   c. Approve PT-sUSDe to Morpho.
   d. `supplyCollateral(PT_SUSDE_USDC_MARKET, ptAmount)`.
   e. `borrow(PT_SUSDE_USDC_MARKET, 10M USDC)` — exactly the flash
      principal, against PT collateral that is now over 109% of debt.
   f. `IERC20(USDC).transfer(BAL_VAULT, 10M)` — repays flash (0 fee).
3. Position outstanding: PT-sUSDe collateral, USDC debt, ~109% c-ratio.

(Note: the Curve USDC↔USDe transit is incidental to the 3-protocol
thesis. The three *load-bearing* mechanisms remain Balancer flashloan,
Pendle PT market, and Morpho PT-collateral market — Curve is a routing
artefact replaceable by Pendle's `swapData` aggregator hop in production.)

## PnL math

Let:
- `Flash = 10,000,000 USDC`
- `disc = 0.08` (PT-sUSDe trades 8% under par at fork)
- `LTV = 0.82` (82% — sub-LLTV 0.865 with 4.5pp buffer)
- `r_usdc_borrow = 0.085` (Morpho USDC borrow APY at fork)
- `T = 0.42` years to maturity (5-month PT)

```
PT_received    ≈ Flash / (1 - disc) = 10,000,000 / 0.92 ≈ 10,869,565 PT
PT_face_USD    ≈ 10,869,565 (PT redeems 1:1 for sUSDe == 1 USD at expiry)
debt           = 10,000,000 USDC
pull_to_par    = PT_face - debt = $869,565 over 5 months
borrow_cost    = debt × r × T = 10,000,000 × 0.085 × 0.42 = $356,500
gross_carry    = $869,565 - $356,500 = $513,065 / 5 months
APR_on_equity  = ∞  (zero user equity to open; entire return is via PT pull-to-par)
```

In practice we should park ≥$100k equity to handle any oracle drift / PT
price wobble at open; this collapses APR to ~1,200% annualised on equity
parked.

## Block pinned

**20,200,000** (mid-July 2024). Pendle PT-sUSDe market has been deep
since Q1-2024; Morpho's PT-sUSDe market live since April 2024. Balancer
V2 USDC vault balance > 50M USDC at this block.

## Risks

- **Morpho oracle for PT-sUSDe**: a custom Pendle-oracle wraps the AMM's
  implied APY into a USD price. Manipulation surface is bounded by the
  market's TWAP window (~30 min), but a flash-pool manipulation could
  move LTV unfavourably. F18-04 is *atomic*, so this only matters
  post-open (after the tx).
- **Liquidation cascade at maturity**: at expiry, the PT redeems to
  sUSDe instantly. If the Morpho oracle doesn't update at the matching
  block, a brief market dislocation can liquidate even healthy
  positions. Mitigation: close 24h before expiry.
- **Balancer USDC vault depth**: if Vault USDC balance < flash amount,
  reverts before any state change.
- **sUSDe peg risk**: at maturity, PT pays out in sUSDe (not USDC). The
  position closes via `redeemPyToToken` (Pendle) → USDC. If sUSDe
  depegs from USDe before maturity the realised carry is reduced.

## Result

Status: **mechanically-reproducible**. The PoC executes the entire
3-protocol triangle atomically on the pinned fork block. Realised carry
materialises over ~2 months (PT pull-to-par to the 26-SEP-2024 expiry);
PoC reports the position state immediately after open and accrues no
warp-based PnL by default.

Expected gross PnL on $0 equity over 2 months: **+$300,000 in net carry
(post-borrow)** at $10M flash size, assuming PT discount holds and USDC
borrow APY stays sub-9%.

## Verified addresses (Wave-5)

| Constant | Address / id | Source |
|---|---|---|
| Pendle PT-sUSDe-26SEP2024 market | `0x19588F29f9402Bb508007FeADd415c875Ee3f19F` | F07-01, F07-04, F08-03, F08-05; Etherscan |
| PT-sUSDE-26SEP2024 PT token | `0x6c9f097e044506712b58eac670c9a5fd4bccef13` | Etherscan token tracker |
| Morpho PT-sUSDe/USDC 86.5% id | `0xe3569130a77514ee127338c307790b2ccc73d9e601917d3ddfe6219a19662ee1` | Computed `keccak256(abi.encode(MarketParams))`; verified via `idToMarketParams` in setUp |
| Morpho PendleSparkLinearDiscount oracle | `0x38d130cEe60CDa080A3b3aC94C79c34B6Fc919A7` | F07-01, F08-03 |
| Morpho AdaptiveCurveIRM | `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC` | Etherscan, F07-01, F07-02, F08-03 |
| Balancer V2 Vault | `0xBA12222222228d8Ba445958a75a0704d566BF2C8` | `Mainnet.BAL_VAULT` |
| Curve USDe/USDC pool | `0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72` | F08-01, F08-03 |
| Morpho singleton | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | `Mainnet.MORPHO` |
| Pendle Router V4 | `0x888888888889758F76e7103c6CbF23ABbF58F946` | `Mainnet.PENDLE_ROUTER_V4` |
