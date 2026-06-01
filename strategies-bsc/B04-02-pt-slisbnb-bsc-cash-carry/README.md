# B04-02: PT-slisBNB BSC cash-and-carry (BNB staking yield locked)

## Mechanism

Lock in a fixed BNB-denominated APY by buying Pendle PT-slisBNB at a
discount and holding to maturity. Composes:

1. **Lista DAO slisBNB** — non-rebasing BNB LST. `ListaStakeManager.deposit`
   mints slisBNB at the canonical exchange rate; this is the underlying that
   the Pendle SY-slisBNB wraps.
2. **Pendle Router V4 on BSC** — `swapExactTokenForPt` with `tokenIn=BNB`
   (or `WBNB` if the SY uses the wrapped form) into the
   `PT-slisBNB-25SEP2025` market. The router auto-mints slisBNB at the
   StakeManager exchange rate then sells SY for PT, so the trader sees only
   the BNB-denominated fixed yield (≈ slisBNB stake APY + AMM premium).
3. **Hold to maturity → PT 1:1 SY** — `vm.warp` past expiry; `redeemPyToToken`
   with `tokenOut=BNB` returns native BNB. The realized carry =
   `(slisBNB_value_at_maturity / pt_entry_cost) - 1`.

## Why it composes

- BNB stake APR (slisBNB ≈ 4 % at the pinned block) is paid to *whoever
  holds SY*. Pendle splits SY = PT + YT, so PT-holders receive
  `(face - discount)` of BNB at maturity regardless of whether stake APR
  spikes or drops in between. **Pure rate-lock.**
- Pendle's BSC market has thinner liquidity vs. mainnet, so PT-slisBNB
  trades at a steeper discount → implied fixed APY is ~1-2 % above
  spot stake APR.
- Cross-asset hedging: a BNB-denominated PT position is the ideal hedge
  for a slisBNB collateral loop on Venus (B01-01). A trader running both
  ends up `delta-neutral` on BNB stake-rate moves.

## Preconditions

- BSC block where `PT-slisBNB-25SEP2025` market is live with `> 50 000 BNB`
  notional liquidity.
- `BSC.PENDLE_ROUTER_V4` resolves to the deployed Pendle BSC router.
- `BSC.LISTA_STAKE_MANAGER` is not paused (SY mint path).

## Strategy steps

1. Fund test contract with `EQUITY_BNB = 100 ether` (native).
2. Approve Pendle Router V4 to receive `msg.value`.
3. `swapExactTokenForPt(...{tokenIn=BNB sentinel, tokenMintSy=BNB sentinel,
   netTokenIn=100 ether}, ...)`. Router auto-converts BNB → slisBNB → SY → PT.
4. Log `ptOut` and implied entry price `1 - ptOut*slisBnbRate/equity`.
5. `vm.warp(expiry + 1 hours)`.
6. `redeemPyToToken(..., output{tokenOut=BNB})`. The router goes
   PT → SY → slisBNB → BNB (via StakeManager preview or PCS hop).
7. PnL = `final_bnb - 100 ether`.

## PnL math

Per 100 BNB principal, ~6-month maturity:
- Implied BNB-denominated fixed APR: ~5-6 % (slisBNB stake APR ~4 % +
  AMM discount premium ~1.5 %).
- 6-month BNB-yield: `100 × 0.055 × 0.5 = +2.75 BNB`.
- At $600 / BNB: ≈ **$1,650 per 100 BNB held to maturity**.

Gas: similar to B04-01 — ~700 k gas, < $0.50 on BSC.

## Block pinned

`FORK_BLOCK = 42_000_000` — same band as B04-01 to keep cross-strategy
comparison clean. Re-pin once BSC RPC is available + slisBNB market
expiry verified.

## Addresses used

- `BSC.PENDLE_ROUTER_V4` — Pendle BSC router. **TODO verify** vs deployed BSC.
- `BSC.slisBNB` = `0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B`.
- `BSC.LISTA_STAKE_MANAGER` = `0x1adB950d8bB3dA4bE104211D5AB038628e477fE6`.
- `BSC.WBNB` = `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c`.
- `LOCAL_PT_SLISBNB_MARKET_25SEP2025` — **inline placeholder**, must be
  verified on Pendle's BSC subgraph. PoC uses `try/catch` so a wrong
  address degrades to a no-op.

## Risks

- **slisBNB validator slashing** — would reduce the BNB-amount the SY
  redeems for at maturity, hurting PT-holders. Mitigation: Lista's
  validator set is over-collateralized via insurance fund.
- **PT discount widening pre-maturity** — only matters if unwound early.
- **Lista StakeManager withdrawal queue** — at maturity the router must
  convert slisBNB → BNB. If StakeManager unbond is queued, the router falls
  back to a PCS slisBNB/WBNB swap (typical slippage 0.2-0.4 %).
- **BSC Pendle router not deployed at expected address** — PoC catches.

## Result

Status: **theoretical** (BSC RPC missing; PoC compiles, degrades gracefully).
Expected PnL: **+2.5 to +3.0 BNB per 100 BNB held to 6-month maturity**.
