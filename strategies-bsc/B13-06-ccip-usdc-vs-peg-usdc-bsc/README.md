# B13-06: CCIP-bridged USDC vs Binance-Peg USDC on BSC

## Family
B13 — Cross-chain bridge LST/stable discount arbs.

## Thesis
BSC has at least three USDC variants:
1. **Binance-Peg USDC** (`0x8AC76a...80d`) — the canonical PCS pool token.
2. **Native Circle USDC** (Circle issued natively on BSC since Sep-2024) —
   token contract distinct from the Binance-peg.
3. **CCIP USDC** — the lock/mint or burnMint-pool USDC variant created by
   Chainlink CCIP token pools. Distinct ledger from #2.

The CCIP variant moves through `ccipSend` (atomic-from-sender's-POV, with
~3-5 min finality on the destination via CCIP DON). When ETH->BSC volume
spikes, the CCIP-USDC supply on BSC overruns the routing capacity into the
PCS Stable pools, and it trades at **5-15 bp discount** to USDT inside
the PCS v3 USDT/USDC_ccip pool.

## Bridge primitive
- **Chainlink CCIP `ccipSend`** with token-pool burnMint mode.
- Plus **PCS Stable router** as a third venue to monetise the residual
  basis on the way out.

## Mechanism count: **3-mechanism**
1. PCS v3 flash (USDT/USDC_native 1bp pool) — cheap loan.
2. PCS v3 swap USDT -> USDC_ccip — captures the discount.
3. CCIP `ccipSend` — atomic burn on BSC, mint on ETH out-of-band.
4. PCS Stable router for any residual USDC_ccip -> USDC_native (third
   venue; only triggered if a portion is kept on BSC).

## Atomic vs positional
**Positional.** The PCS swap + CCIP burn lock in the spread within one
block, but the ETH-side credit needs the CCIP DON window. Buffer repays
the flash.

## Block pinned
- `FORK_BLOCK = 45_500_000` — placeholder. Re-pin to a CCIP burnMint
  inflow burst (verify via Chainlink's CCIP explorer). TODO.

## PnL math
At 12 bp discount + 4 bp basis recovery, $750k notional:
- Discount capture: `750_000 * 0.12% = $900`.
- Stable basis on residual (10% of notional): `75_000 * 0.04% = $30`.
- Flash fee (1 bp): `$75`.
- CCIP fee: ~$0.50.
- PCS v3 fee leg 1: 5 bp = $375.
- Net: **~$480**.
Higher payoff when discount is wider (>= 20 bp).

## Preconditions
- `CCIP_ROUTER` deployed on BSC and exposing `ccipSend`/`getFee`. TODO
  verify mainnet address.
- `USDC_CCIP` token deployed by Chainlink's burnMint pool. TODO verify.
- `PCS_STABLE_ROUTER` has a USDC_ccip / USDC_native lane (check Wombat /
  PCS stable curve listings).
- ETH chain selector `5009297550715157269` is the standard CCIP value
  — TODO confirm at execution time.

## Risks
- **CCIP token-pool throttling** can rate-limit large sends, forcing the
  burn to revert and unwinding the flash leg with a loss on the swap fee.
- **Variant ambiguity**: the "USDC_ccip" symbol on PCS often gets aliased
  with Binance-Peg USDC; verify the pool's `token0`/`token1` reads
  match the burnMint pool token before committing.
- **CCIP DON delay** > 5 min in congested windows; PnL is booked at
  swap+burn time but ETH-side recovery is delayed.

## TODO
- Resolve `CCIP_ROUTER` + `USDC_CCIP` addresses on BSC.
- Confirm `ETH_CCIP_SELECTOR` constant.
- Re-pin `FORK_BLOCK` against a CCIP inflow window.
- Verify PCS_STABLE_ROUTER lane includes USDC_ccip.
