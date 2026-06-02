# B10-01 — Venus VAI mint vs Lista lisUSD borrow funding-cost basis

## Family

B10 · Cross-stablecoin CDP basis.

## Thesis

BSC has **two native CDP-issued stables** that both target $1:

- **Venus VAI** — minted via `VAIController.mintVAI()` against the borrower's
  Venus Core supply position. Mint fee + base rate accrue at a Venus-governed
  rate that historically sits at **2-4 % APR** (sometimes 0 % during reward
  campaigns).
- **Lista lisUSD** — borrowed from `IListaInteraction.borrow(token, amt)` on
  top of slisBNB/asBNB CDPs. Lista's stability fee floats with the SF
  parameter and historically prints at **4-8 % APR**.

A user who needs **lisUSD-shaped exposure** (e.g. to supply into a Lista
incentive vault, to LP in PCS `lisUSD/USDT`, or to use as collateral elsewhere)
faces a choice:

1. Open a Lista CDP and borrow lisUSD directly at the higher SF, OR
2. Open a Venus position (which they likely already have for vBNB / vUSDT
   leverage), mint VAI at the lower fee, and **swap VAI → lisUSD** on
   PancakeSwap.

When `VAI_mint_APR + PCS_swap_slippage_amortised < Lista_lisUSD_SF`, the
second path is strictly cheaper financing for the same downstream lisUSD
position. The strategy captures this funding-cost spread as **carry over the
hold horizon**.

## Mechanism stack

1. Pre-existing Venus collateral position (modelled by supplying USDT to
   `vUSDT` so the test runs against a real BSC contract surface).
2. `comptroller.enterMarkets([vUSDT])` and verify the resulting account
   liquidity supports a VAI mint.
3. Call `VAIController.mintVAI(amount)` — mints VAI 1:1 against the borrowing
   capacity, accrues at `baseRate + vaiFee`.
4. Swap `VAI → lisUSD` on PancakeSwap (v2 stable pool or v3 stable tier).
   This is the leg that makes the carry venue-equivalent to a direct Lista
   borrow.
5. Hold `lisUSD` for `HOLD_DAYS`. Funding accrues on the VAI debt at the
   Venus rate; the lisUSD sits idle (or, in a richer variant, is supplied to
   the Lista PSM-like sink at its supply yield).
6. Unwind: swap `lisUSD → VAI` on PCS, call `VAIController.repayVAI(amount)`
   to extinguish the debt, withdraw collateral.

Net carry per unit notional:

```
carry_bps = (Lista_SF - Venus_VAI_rate) × hold_years
          - 2 × PCS_stable_swap_fee_bps
          - amortised_gas
```

With the Lista SF − Venus VAI rate band at **~250 bp** and PCS stable swap
fee at 1-4 bp per leg, a 30-day hold breaks even ≈ instantly and earns ~20 bp
of notional.

## Why this is genuinely a "B10" play (not just B03 or B06)

Both legs are stables that target the same peg, so it does *not* show up as
a B03 lisUSD-only CDP strategy nor as a B06 Venus-IRM-only play. The alpha
is the **cross-issuer funding-cost basis** between two CDP-class stables on
the same chain, captured via the AMM that links them. It is the canonical
B10 thesis.

## Address / ABI verification

- `BSC.VAI = 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7` — verified
  canonical Venus VAI on BscScan.
- `BSC.VENUS_COMPTROLLER = 0xfD36...8384` — verified.
- VAIController (the contract behind `mintVAI` / `repayVAI`) is **NOT** in
  the BSC.sol address book. We pin it locally as `LOCAL_VAI_CONTROLLER` and
  flag for verification.
- `BSC.lisUSD = 0x0782b6...41E5` — verified.
- PCS `VAI/USDT/lisUSD` routing: assumed via `USDT` as the common quote leg
  (VAI → USDT → lisUSD); a richer variant could use Wombat or a dedicated
  PCS StableSwap pool if one exists for `VAI/lisUSD`.

## Status & PnL

- **Status:** offline-first PoC. Compiles against the family-allowed
  interface surface (`IVToken`, `IVenusComptroller`, `IListaInteraction`,
  `IPancakeV2Router`). On-fork run requires `BSC_RPC_URL` and a pinned block
  where the VAI mint controller is unpaused and the PCS `VAI/USDT` pool has
  liquidity > $100k.
- **PnL model:** `notional = $1m`, `hold = 30 days`, `Lista_SF − Venus_VAI_rate
  = 250 bp`, `swap_legs = 2 × 4 bp = 8 bp`. Net carry =
  `1_000_000 × (250 - 8) bp × 30/365 = $1,989`.
- Offline PoC funds the position synthetically (skipping the live Venus mint
  call) and asserts the PnL block matches the model within rounding.

## TODO

- Pin `LOCAL_VAI_CONTROLLER` once the Venus team confirms canonical proxy
  address; promote to `BSC.sol` in a B10-agnostic PR.
- Replace the constant-rate carry model with a fork-time read of
  `VAIController.baseRateMantissa` and `IListaInteraction.stabilityFee` (the
  latter only available after the ABI is hardened in B03).
- Add a **funding-flip detector**: when `Venus_VAI_rate > Lista_SF`, the
  trade reverses (borrow lisUSD, swap to VAI, repay VAI debt instead of
  Venus borrow). The on-chain rate-quote scaffolding is the same.
