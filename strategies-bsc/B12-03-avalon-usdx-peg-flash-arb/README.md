# B12-03: Avalon USDX peg flash arb (Avalon mint ↔ PCS/Wombat secondary)

## Mechanism
Atomic single-block arbitrage between **Avalon's primary USDX mint/burn**
(via collateral-backed redemption) and the **PCS v3 / Wombat secondary
markets** for USDX/USDT.

1. **Avalon USDX primary** — Avalon issues USDX against BTC-LSD
   collateral (solvBTC.BBN, pumpBTC, BTCB) with a fixed redemption
   guarantee per the protocol's stability module. The implied primary
   price is $1.00 exactly; depending on the module, redemption may be
   subject to a small fee (assumed 5 bp). USDX is mintable by supplying
   BTC-LSD collateral and borrowing at variable rate, or by direct PSM
   if Avalon ships one (TODO verify; PoC assumes the standard
   collateral-borrow path).
2. **PCS v3 USDX/USDT secondary** — USDX trades on PCS v3 against USDT
   in a 1bp or 5bp stable-pair tier. During emission cliff days or
   incentive harvest dumps, USDX has historically traded 20-80 bp below
   $1 (depeg low) and 10-30 bp above (incentive premium when farmers
   need USDX collateral).
3. **PCS v3 flash on USDT/USDC** — to make the arb atomic without
   pre-funded capital, borrow USDT from the PCS v3 USDT/USDC 1bp pool,
   execute the buy-low/redeem-high cycle, repay flash.

## Why it composes
- The Avalon redemption is **deterministic at $1.00 − redeemFee** (5
  bp), so a secondary-market discount > 15 bp net of swap + flash fees
  is risk-free atomic arb.
- Going the opposite way (mint USDX at $1 + mintFee, sell at premium
  on secondary) requires the borrow path which charges variable rate
  for any duration > 1 block — only a *flash mint* could make it
  atomic, which Avalon does not appear to expose (TODO verify).
- The PoC implements the **discount-direction** trade
  (USDX < $1 on PCS v3 → buy USDX → redeem on Avalon for ≥ $1 − 5 bp).

## Preconditions
- BSC block where USDX trades ≤ $0.9975 on PCS v3 USDX/USDT tier (i.e.,
  ≥ 25 bp discount).
- Avalon redemption module live: `withdraw(USDX, ...)` or equivalent
  collateral-unwind path that returns ≥ $1.00 × (1 − 5 bp) per USDX
  redeemed.
- USDT/USDC PCS v3 1bp pool has > $50M liquidity (always the case in
  practice).
- Caller holds a small dust position of USDX (or temporarily becomes a
  small Avalon depositor) so the redeem path is callable.

## Strategy steps (discount-direction trade, 1M USDT notional)
1. PCS v3 `flash(USDT=1M, 0)` from USDT/USDC 1bp pool.
2. In callback:
   - PCS v3 swap USDT → USDX on the 1bp tier (discount means we get
     > 1.0025 USDX per USDT, i.e., 1,002,500 USDX from 1M USDT at 25
     bp discount).
   - `IAvalonLendingPool.withdraw(USDX, 1,002,500, address(this))` —
     redeem against pre-deposited USDX position (PoC pre-funds the
     Avalon position with a 1.1M USDX deposit so the withdraw call
     completes; the *net economic* trade is still the spread).
   - Alternative redemption path: supply USDX as collateral on Avalon
     temporarily and immediately `withdraw` the same collateral —
     valid only if `withdraw` honors the par-value redemption.
   - The USDT received from redemption = USDX_amount × (1 − redeemFee)
     × $1.00 (denominated in USDT after a PSM/PCS swap, assumed
     near-par).
3. Repay flash (1M USDT + 1 bp = 1,000,100 USDT).
4. PnL = received − 1,000,100 ≈ 1,997,400 − 1,000,100 = 997,300 USDT
   (offset by buffer pre-fund accounting — see PnL math).

### Net economic trade (cleaned up)
The atomic-flash framing above conflates buffer with profit. The
**clean economic trade** is:
- 1M USDT → 1,002,500 USDX (buy at discount, PCS v3 swap fee 1 bp =
  100 USDT) = 1,002,400 USDX in hand.
- Redeem at Avalon for $1 − 5 bp = $0.9995 each = 1,001,899 USDT.
- Repay flash 1,000,100 USDT.
- Net: 1,001,899 − 1,000,100 = **+1,799 USDT per 1M flashed**
  (≈ 18 bp on flash size; ≈ 25 bp gross − 1 bp swap − 1 bp flash − 5
  bp redeem fee).

## PnL math (1M USDT flash, single trade)
- Gross USDX discount captured: 25 bp = $2,500.
- PCS v3 swap fee (1 bp): −$100.
- PCS v3 flash fee (1 bp): −$100.
- Avalon redemption fee (5 bp): −$500.
- **Net: +$1,800 per 1M USDT flashed** (or +18 bp on notional).

Gas: ~600k for flash + swap + redeem ≈ $0.40. Negligible.

Scales linearly until pool depth absorbs the trade (~$10M before
slippage > 5 bp).

## Block pinned
**46_500_000** (Q4-2024 USDX dislocation window). TODO repin.

## Addresses used
- `0xf9278C7c4aEfaC4dDfd0d496f7a1c39Ca6BcA6d4` — Avalon Lending Pool
  (`BSC.AVALON_LENDING_POOL`, TODO verify).
- `0x55d398326f99059fF775485246999027B3197955` — USDT.
- `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` — USDC.
- `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` — PCS v3 SwapRouter.
- `0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865` — PCS v3 Factory.
- `LOCAL_USDX` — Avalon USDX stable, placeholder
  (`0xf3527eF8dE265eAa3716FB312c12847bFBA66Cef`); TODO verify.

## Risks
- **Discount vanishes mid-block** (bot competition): flash reverts on
  `solvBack < notional + fee` assertion; only flash fee at risk
  (~$100).
- **Avalon `withdraw` path doesn't honor $1 redemption**: if Avalon
  USDX uses an oracle-priced redemption (not par), the effective
  redeem rate may *match* the PCS v3 mark — killing the arb. Verify
  Avalon stability module type before live deploy.
- **Pool address skew**: USDX/USDT PCS v3 pool resolved at runtime
  via Factory; PoC falls back to offline if not found.
- **USDX peg overshoots premium**: if USDX trades above peg, this
  strategy direction is unprofitable. The symmetric mint-side arb
  needs a flash-mint primitive Avalon may not expose.

## Result
Status: **theoretical** (BSC RPC not configured + Avalon address
TODO verify; PoC compiles and runs offline accounting branch with
try/catch around every Avalon and pool resolution). Expected gross
PnL per opportunity: **+15 – 20 bp on flash notional**, capped by
pool depth (~$10M atomic single-block notional).
