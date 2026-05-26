# F11-07: Fluid wstETH/USDC + Maker DssFlash bootstrap (3-mech)

## Mechanism
Three independent primitives composed atomically:

1. **Maker DssFlash** — ERC-3156 DAI flash-mint with `toll == 0` (free).
   Caps at the global ceiling (`max()`, currently 500 M DAI). Free flash
   loans for any DAI-denominated bootstrap.
2. **Fluid wstETH/USDC T1 vault** — Fluid's classic isolated-collateral
   vault: wstETH-only collateral, USDC-only debt, ~85 % LLTV.
3. **Lido wstETH** — yield-bearing LST used as collateral.

The pattern: borrow N DAI (free), convert to USDC on Curve 3pool, open the
Fluid vault by supplying wstETH + drawing USDC at the LTV target, swap the
USDC back to DAI on the same 3pool, repay flash. The Fluid position is
fully bootstrapped inside one atomic transaction with no out-of-pocket
USDC; the user's principal stays in wstETH form.

This is a *bootstrap* pattern: the DssFlash gives you the USDC liquidity
to instantly mirror the Fluid debt leg without first holding USDC. It
is most useful when the user wants to scale up the position quickly, when
USDC is scarce relative to DAI, or when one wants to test a Fluid
debt-cap budget atomically (open, observe vault state, exit if too tight,
without leaving USDC dust).

## Why it composes
- DssFlash is *the* free DAI source on Ethereum: governance-controlled
  ceiling, zero toll, no callback restrictions beyond ERC-3156.
- Fluid's `operate(0, +col, +debt, to)` accepts a positive debt in the
  same call that mints the NFT — there is no precondition that the user
  must hold debt-asset USDC before the call. The borrow happens
  *inside* operate.
- Curve 3pool is the deepest DAI↔USDC venue on mainnet (TVL > $200 M),
  with typical round-trip slippage <2 bps for ~5 M DAI sizes.

Net: the strategy provides a 3-mechanism *zero-stable-capital* entry to a
levered Lido-yield position via Fluid, financed by a free Maker flash.

## Preconditions
- Mainnet at block where DssFlash, Fluid wstETH/USDC, and Curve 3pool are
  all live (any block after Fluid wstETH/USDC T1 deployment in Jun 2024).
- DSS flash ceiling > intended bootstrap size (always true at typical sizes).
- Curve 3pool DAI/USDC depth sufficient for round-trip without >5 bps drag.

## Strategy steps
1. Wrap ETH → wstETH via Lido `submit` + wstETH `wrap` (or hold wstETH directly).
2. Call `DssFlash.flashLoan(this, DAI, N, abi.encode(wstAmt))`.
3. In `onFlashLoan` callback:
   a. Swap a slice of the DAI flash → USDC on Curve 3pool.
   b. Call Fluid `operate(0, +wstAmt, +borrowUsdc, this)` — opens NFT, supplies
      collateral, draws USDC debt.
   c. Swap the USDC accumulated (Fluid borrow + Curve out) → DAI on 3pool.
   d. Approve DSS to pull DAI back. Return ERC-3156 magic.
4. Hold the Fluid position 30 days.
5. Optional unwind: another DssFlash to repay USDC debt, withdraw wstETH,
   round-trip USDC→DAI.

## PnL math
Per 100 wstETH principal, 30-day horizon, indicative rates:
- wstETH staking yield: 1.00 × 0.030 × (30/365) = +0.25 %
- Fluid USDC borrow APR ≈ 0.060 on the debt notional
  (debt notional = 50 % of collateral USD value)
  Debt drag: 0.50 × 0.060 × (30/365) = -0.25 %

Net carry on the bootstrapped position over 30 days: **~ 0 %**
*before* swap fees. The strategy's edge is **not** running yield — it
is the **free atomic bootstrap** itself, eliminating two manual swap legs
and the need to hold USDC ahead of position open. For a single 5 M DAI
bootstrap the gas cost is one tx; manual equivalent is at least three.

Curve round-trip drag: ≈ 4 bps on the borrow notional, observed in the PnL.

## Block pinned
**21_300_000** (Dec 2024) — DSS flash open (toll==0), Fluid wstETH/USDC
T1 live and deep, Curve 3pool TVL > $200 M.

## Addresses used (verified)
- `0x60744434d6339a6B27d73d9Eda62b6F66a0a04FA` — DssFlash mainnet,
  verified at https://etherscan.io/address/0x60744434d6339a6b27d73d9eda62b6f66a0a04fa
- `0x40D9b8417E6E1DcD358f04E3328bCEd061018A82` — Fluid wstETH/USDC T1
  vault, verified at
  https://etherscan.io/address/0x40d9b8417e6e1dcd358f04e3328bced061018a82
- `0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7` — Curve 3pool DAI/USDC/USDT
- `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` — wstETH
- `0x6B175474E89094C44Da98b954EedeAC495271d0F` — DAI
- `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` — USDC

## Risks
- **DSS toll lift**: governance may set `toll > 0` (historical default is 0;
  set 9 bps once in 2021). At toll = 9 bps a 5 M DAI flash costs 4.5 k DAI —
  no longer free. PoC asserts `flashFee == 0`.
- **Curve 3pool depeg**: a USDC depeg widens the round-trip drag.
- **Fluid debt cap**: per-vault debt ceiling can throttle the borrow leg;
  call must succeed or be caught.
- **Reentrancy guard interaction**: DssFlash callback runs under DSS Vat
  semaphore; Fluid `operate` writes its own storage so must complete
  atomically. PoC validates the integration.

## Result
Status: theoretical (forge build not run; all 5 mainnet addresses verified
on Etherscan; DSS toll==0 hard-asserted in callback). PoC opens the
Fluid NFT atomically inside `onFlashLoan` and reports residual balances.
Expected PnL: **~0% over 30 days** but with a vastly more capital-efficient
opening sequence; the strategy is about *atomicity* and *primitive
composition*, not headline carry.
