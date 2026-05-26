# F08-05: DssFlash + Aave e-mode + PT-sUSDe sleeve (3-mech)

## Mechanism

Single-transaction composition that uses **three independent leverage
primitives** to assemble a barbelled sUSDe carry book:

1. **Maker DssFlash** mints **DAI free of fee** (toll=0) up to a 500M
   ceiling. ERC-3156 callback. No collateral needed — DssFlash uses an
   internal Vat operation that does not consume any actual DAI inventory.
2. **Pendle V4 PT-sUSDe** sleeve gives fixed-rate locked carry over the
   PT-sUSDe-26SEP2024 horizon (~50d at fork block) at the implied APY
   (~14-18% annualised in mid-2024).
3. **Aave v3 stablecoin e-mode** (category 8, activated by AIP-369)
   accepts sUSDe alongside USDT/USDC/DAI as a 90% LTV correlated class.
   The borrow leg of the looped sUSDe carry is in DAI — which is also
   the asset we owe to DssFlash — so the flash closes atomically
   without any Curve round-trip on the close leg.

The strategy is structured as a single Maker flash. Inside the callback:

```
DssFlash(DAI, 5M)               -- toll = 0
  total = EQUITY_DAI + 5M DAI
  ptSleeve  = 15% of total       -- locked-yield PT sleeve
  loopSleeve = 85% of total      -- looped Aave e-mode sUSDe

  ptSleeve:   DAI -3pool-> USDC -USDe/USDC-> USDe -Pendle-> PT-sUSDe (hold)
  loopSleeve: DAI -3pool-> USDC -USDe/USDC-> USDe -sUSDe.deposit-> sUSDe
              -> Aave.supply(sUSDe)  (in e-mode 8)
  
  Aave.borrow(DAI, flashAmount + 0_fee)
  -> repay DssFlash via outer approval
```

Net result post-tx: ~5x notional sUSDe staked into Aave e-mode (90% LTV)
**plus** a ~equity-sized PT-sUSDe sleeve, all bootstrapped from a single
1M DAI equity outlay — gross notional ~6M with the flashmint.

## Why it composes

The three primitives are *complementary*, not redundant:

- **DssFlash** breaks the bootstrap chicken-and-egg: a leveraged
  e-mode loop requires collateral *before* it can borrow, but the
  collateral itself is fundamentally borrowed. Flashminting bypasses
  this by injecting 5M of DAI into the tx for the duration of the
  callback only.
- **PT-sUSDe** decouples a portion of the position from the
  funding-rate variance. If sUSDe APY collapses post-entry, the PT
  sleeve still redeems at par on 26 SEP 2024. This acts as a *hedge*
  against the very risk that motivates the looped position (carry
  collapse).
- **Aave e-mode** is uniquely suited to the looped leg because the
  90% LTV is materially higher than the default sUSDe LTV (~75% pre
  e-mode), turning a 4-loop carry from ~4x to ~9x notional at the
  limit. Crucially the borrow side is DAI — matching the flash
  currency — so no on-close swap is needed.

This is structurally different from F08-01 (Morpho-based, USDC debt,
no flash) and F08-04 (Aave-based, USDT debt, no flash). The flashmint
+ PT sleeve are net-new mechanisms over both F08-01 and F08-04.

## Preconditions

- Fork block after AIP-369 enabled sUSDe e-mode (cat 8) on Aave v3.
  Block `20_400_000` (Aug 2024) is comfortably post-activation.
- Maker DssFlash max DAI ceiling > 5M (the protocol default has been
  500M since DIP-32).
- Pendle PT-sUSDe-26SEP2024 market liquid for a ~750k USDe buy with
  acceptable slippage (< 30 bps at the pinned block).
- Curve 3pool depth > 5M DAI on the DAI→USDC leg.
- Curve USDe/USDC depth > 5M USDC on the USDC→USDe leg.

## Strategy steps

1. `_fund(DAI, this, 1M)` — seed equity.
2. Approvals for DssFlash, Aave, Curve 3pool, Curve USDe/USDC, Pendle,
   sUSDe vault.
3. `setUserEMode(8)` to enter stablecoin e-mode *before* depositing.
4. `DssFlash.flashLoan(DAI, 5M)` → calls `onFlashLoan`.
5. Inside `onFlashLoan`:
   a. Split total DAI: 15% PT sleeve, 85% loop sleeve.
   b. PT sleeve: DAI → USDC (3pool) → USDe (USDe/USDC) → PT-sUSDe (Pendle).
   c. Loop sleeve: DAI → USDC (3pool) → USDe → sUSDe → Aave.supply.
   d. `Aave.borrow(DAI, 5M)` (fee=0, so exactly 5M repay).
   e. Return `ERC3156FlashBorrower.onFlashLoan` selector keccak.
6. Outer `transferFrom(this, DssFlash, 5M)` repays principal+fee.
7. Log Aave coll/debt/HF and PT balance.

## PnL math

Let:
- `y_s` = sUSDe trailing APY ≈ 0.14 (Aug 2024)
- `y_b` = Aave DAI variable borrow APY ≈ 0.07 (lower than USDT)
- `y_pt` = PT-sUSDe implied APY ≈ 0.16 (~50d to maturity)
- `L_eff` = effective Aave e-mode leverage ≈ 1 / (1 - 0.87) ≈ 7.7x
- `α` = 0.85 (loop allocation), `1-α` = 0.15 (PT sleeve)

Equity-weighted APY (ignoring the modest gross-up from the flashmint
itself, which is repaid 1:1):

```
loop_apy_on_loop_sleeve  = L_eff * y_s - (L_eff - 1) * y_b
                        ≈ 7.7 * 0.14 - 6.7 * 0.07
                        ≈ 1.078 - 0.469
                        ≈ 0.609   (~61% APY on loop equity)

pt_apy_on_pt_sleeve      ≈ y_pt = 0.16

equity_apy = α * loop_apy + (1-α) * pt_apy
           ≈ 0.85 * 0.609 + 0.15 * 0.16
           ≈ 0.518 + 0.024
           ≈ 0.542    (~54% APY on equity)
```

Over a 30-day horizon: ~4.5% gain on 1M DAI equity ≈ $45k gross,
net of Curve fees (~$3k across 3 hops × 3 swaps × 8M aggregate
notional × ~4 bps) and gas (~1.2M gas, ~$60).

Expected **net PnL ~$42k on a single 30d run, single-block bootstrap**.

## Block pinned

**20_400_000** (~Aug 2024). Verifications at this block:
- AIP-369 sUSDe e-mode (cat 8) active on Aave v3.
- DssFlash maxFlashLoan(DAI) ≥ 500M.
- Pendle PT-sUSDe-26SEP2024 market live with ~50d to maturity.
- Curve USDe/USDC pool depth > $200M.

## Risks

- **Atomic-tx revert**: if any leg reverts (Aave LTV miscount, Pendle
  slippage > guess, Curve depth, …), the entire tx unwinds. No partial
  state. This is a feature, not a bug.
- **E-mode category drift**: Aave governance may reclassify cat 8.
  Verify on-chain via `getReserveData(SUSDE).configuration` decoding.
- **Aave DAI borrow APY spike**: a sudden utilisation pin at the kink
  causes IRM to ramp 3x; if sustained, the loop becomes loss-making.
- **PT-sUSDe mark-down**: an Ethena depeg event marks the PT below
  expected — but the PT sleeve is held, not loaned, so liquidation is
  not a risk. Worst case is the PT pays off below face.
- **DssFlash toll**: while currently 0, MakerDAO governance can raise
  it. Our callback repays `amount + fee` unconditionally.
- **Pendle expiry pre-redemption**: PT expires 26 SEP 2024. After
  expiry, the position must be redeemed via `redeemPyToToken` or
  similar — the PoC does not exercise the redemption leg.

## Result

Status: theoretical. Forge build not run.

Expected PnL: **~+4.5% over 30 days on 1M DAI equity** at ~6x effective
leverage (Aave loop) + 1x PT sleeve. Equity-USD gain ~$45k gross,
~$42k net of fees and gas. Atomic bootstrap; no intermediate state.
