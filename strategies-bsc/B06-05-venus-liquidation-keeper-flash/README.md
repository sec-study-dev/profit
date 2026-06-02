# B06-05: Venus liquidation keeper — atomic flash + liquidate + DEX

## Family
B06 — Venus V4 isolated pool arbitrage. This strategy turns the Venus Core
liquidation venue into a same-tx riskless keeper using three composed
mechanisms.

## Mechanism (3-mech)
1. **Venus V4 `flashLoan` on Core vUSDT** — supplies the 250k USDT principal
   needed to repay an underwater account. Premium ≈ 9 bp.
2. **Venus `liquidateBorrow(borrower, repayAmount, vBTCB)`** — Compound v2
   inherited selector on the Core vUSDT market. Repays the borrower's
   USDT debt; the Comptroller seizes the equivalent dollar amount of vBTCB
   at the 10 % `liquidationIncentive` bonus. The keeper receives the seized
   vBTCB.
3. **PCS v3 BTCB/USDT 0.05 % swap** — after `redeem`ing seized vBTCB into
   raw BTCB, the keeper sells it into the deepest BSC AMM pool (the PCS v3
   BTCB/USDT pool) using a single-leg swap. The output USDT covers the
   flash repayment; the 10 % liquidation bonus minus swap fee + premium is
   pure keeper PnL.

## Why it composes
- Without the flashLoan the keeper would need 250k USDT idle.
- Without the on-chain DEX leg the keeper would carry BTCB risk until the
  next block.
- Without the per-borrower liquidation check (`getAccountLiquidity`) the
  flash would revert without yielding anything.

The combination yields an **atomic, capital-light, market-neutral keeper**:
all three legs settle inside a single Venus flash callback.

## Addresses (inlined)
- `BSC.vUSDT = 0xfD5840Cd…` — Core vUSDT (flash + liquidate venue).
- `BSC.vBTCB = 0x882C173b…` — Core vBTCB (seize target).
- `LOCAL_PCS_V3_BTCB_USDT = 0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4`
  — PCS v3 BTCB/USDT 0.05 % pool. **TODO verify** at pinned block.
- `TARGET_BORROWER = 0x…C0DE` — synthetic underwater account for offline
  PoC; replaced in live runs by an off-chain scanner that walks
  `Comptroller.getAccountLiquidity` over recent borrowers.

## Block pinned
**42_500_000** — chosen for consistency with the rest of the B06 family.
Re-pin to a block where a real underwater BTCB-collateralised USDT borrower
exists once `BSC_RPC_URL` is set.

## PnL math (per 250k USDT repay, BTCB at $65k)
- Seized BTCB notional = `repay × 1.10 / btcPrice ≈ 4.23 BTCB ≈ $275k`.
- Gross bonus = `repay × 0.10 = $25,000`.
- Flash premium = `repay × 9 bp = $225`.
- PCS v3 swap fee (0.05 % on $275k) ≈ `$137`.
- Gas ~1 M (flash + liquidate + redeem + v3 swap callback) ≈ $0.60.
- **Net keeper PnL ≈ $24,600 per liquidation.**

## Risks
- **No underwater borrower at pinned block.** PoC degrades to a clean
  flash-repay with `+0` PnL (minus gas + premium ≈ $225).
- **`closeFactor` cap.** Venus Core enforces `repayAmount ≤ 0.5 × borrow`.
  PoC uses 250k specifically so most realistic targets are not clipped.
- **`liquidationIncentive` change.** Governance can drop the 10 % bonus.
- **PCS v3 BTCB/USDT pool thinness.** A 4-BTCB market sell may move the
  pool by >50 bp. Production would split across PCS v3 + Thena + Wombat.

## Result
Status: **theoretical, offline**. Expected net **~$24k per successful
liquidation**, degrades to ≈ -$230 on a no-target block. Compiles
without RPC.
