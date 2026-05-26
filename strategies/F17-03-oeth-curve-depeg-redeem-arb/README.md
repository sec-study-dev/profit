# F17-03: OETH/ETH Curve depeg + atomic 1:1 redeem arb

## Mechanism

This strategy exploits a structural feature of **Origin Ether (OETH)**:

- **OETH** (`0x856c4Efb76C1D1AE02e20CEB03A2A6a08b0b8dC3`) — Origin Protocol's
  yield-aggregating rebasing ETH. Underlying composition: Curve LP positions
  (frxETH/ETH, stETH/ETH), Aura/Convex yields, native stETH/rETH/wstETH.
  Yield is paid via a daily upward rebase of OETH balances.
- **OETH Vault** (`0x39254033945AA2E4809Cc2977E7087BEE48bd7Ab`) — the issuer.
  Holders may burn OETH for the underlying basket via `redeem(amount,
  minAmountOut)`. The vault returns the *underlying basket pro-rata*, which
  is essentially ETH-equivalent assets (stETH, WETH, frxETH).
- **Curve OETH/ETH pool** (`0x94B17476A93b3262d87B9a326965D1E91f9c13E7`) —
  2-coin pool, [ETH(0), OETH(1)]. Primary venue for OETH liquidity.

The arbitrage: when the Curve OETH/ETH pool prices OETH below ETH (e.g.
during a redemption-cascade week or large unwind), an actor can:

```
1. Flash-borrow ETH (e.g. via Balancer or Aave V3).
2. Swap ETH -> OETH on Curve at a discount (e.g. 0.998 ETH per OETH).
3. Call OETHVault.redeem(OETHamount, minETH_out) -> receives basket
   (~ETH-equivalent assets). Some basket components are WETH or stETH; convert
   to WETH/ETH.
4. Repay flash loan principal.
5. Profit = (basket_value_in_ETH - flash_principal).
```

Because OETH vault's `redeem` is 1:1 (modulo a small exit fee, currently
0.5%), the arb is profitable whenever:

```
Curve discount > vault exit fee + slippage on basket-to-ETH conversion + flash fee
```

i.e. `> ~0.5% + 0.1% + 0% (Balancer) ≈ 0.6%`.

## Why it composes

This is a **rebase token redemption arb** — a category that does NOT exist
for non-rebasing yield-bearing stables like sDAI (where redemption is
straightforward but the share is always priced at NAV on Curve because there
is no exit-fee gating). The combination is unique because:

1. **Vault redemption mechanic.** OETH has a real on-chain redeem path with
   ETH-equivalent assets as output, unlike USDM/USDY which are gated by KYC.
   This means *anyone* (including PoC test contract) can arb the pool.
2. **Basket settlement.** The redeem returns a basket (multi-asset), so the
   PoC must handle multiple output tokens. Origin's redeem function
   typically returns WETH primarily (since the vault rebalances), so the
   basket conversion is usually a no-op or a small Curve swap.
3. **Rebase-aware accounting.** Because OETH is rebasing, the PoC must use
   the rebasing-aware version of `_fund` (i.e. whale prank, not `deal`) to
   acquire OETH if buying from a holder. But this strategy *swaps* in via
   Curve, so the rebase-funding concern is bypassed.
4. **Composability with flashloan**. Balancer V2 ETH/WETH flash loans are
   free; Aave V3 has a 5bps fee. The pool's flash side allows the entire
   trade to be atomic.

## Preconditions

- Mainnet block where Curve OETH/ETH pool is meaningfully off-peg in OETH's
  disfavor. Such windows occur during:
  - Large redemption events on Origin (e.g. a major LP exiting).
  - OETH withdrawal queues backing up.
  - General L1 ETH-collateralized stablecoin de-pegs that propagate.
- OETH vault `redeem` is unpaused and exit fee is not punitive (>1%).

## Strategy steps

1. Pin fork to a block with observed OETH discount. The PoC reads the live
   Curve pool quote and **only executes if `discount > 60bps`**. On any
   given recent block this may or may not be the case; the PoC asserts
   either a profitable execution or a graceful no-op.
2. Quote: `Curve.get_dy(WETH=0, OETH=1, 100 ETH)` -> if > `100 * 1.006e18 /
   1e18` (i.e. > 100.6 OETH for 100 WETH), execute.
3. Flash-borrow WETH via Balancer V2 (0-fee).
4. In callback:
   - Approve Curve pool; unwrap WETH to ETH (if pool expects native ETH) and
     swap ETH -> OETH.
   - Approve OETH to vault; call `vault.redeem(oethAmount, 0)`.
   - The redeem returns ETH/WETH/stETH/frxETH to the contract. Convert any
     non-WETH to WETH via the relevant Curve pool (stETH pool, frxETH
     pool).
   - Verify total WETH >= flash principal; repay.
5. Profit = residual WETH.

## PnL math

At a 1% discount on $1M notional:
- Buy OETH on Curve: 1000 ETH -> 1010 OETH (assuming `dy = 1010`).
- Redeem OETH: 1010 OETH -> 1010 * (1 - 0.005 exit fee) = 1004.95 ETH worth
  of basket.
- Convert basket to ETH (assume 100% WETH return, no slippage) = 1004.95.
- Repay flash 1000.
- **Profit = 4.95 ETH ≈ $14_850 at ETH=$3000**.

At a 60bps discount (the entry threshold), profit per $1M ≈ 1 ETH ≈ $3000,
which roughly covers gas (~$10) and basket-conversion slippage.

Gas estimate: 1 flash + 2 Curve swaps + 1 vault redeem + 1 basket
conversion ≈ 600k gas. At 30 gwei: 0.018 ETH = $54.

## Block pinned

`20_400_000` (Jul 19 2024). OETH had a brief discount window in mid-Jul
2024 around the Pendle-PT-OETH expiry unwind. PoC tries this block; if the
discount isn't present it falls back to a quote-only no-op path.

## Risks

- **Vault redeem returns non-WETH basket.** If the vault returns stETH
  primarily, the PoC must convert stETH -> WETH via Curve stETH pool, which
  itself can have slippage. Worst observed: 10-20 bps on the stETH pool at
  >$10M size.
- **Vault redeem paused.** Origin governance can pause `redeem` during
  emergencies. PoC detects via revert and reports no-op.
- **Vault exit fee changed.** Currently 0.5%; could rise. PoC reads the
  current fee from `vault.redeemFeeBps()` if exposed, and uses it in the
  break-even quote.
- **Discount priced out.** The expected discount may not be present at the
  pinned block (other arbers were faster). PoC's `no_arb` branch handles
  this.
- **OETH rebase mid-trade.** Unlikely (rebases are end-of-day), but if it
  fires during the flash callback, basket math could shift mid-frame. PoC
  is single-block-atomic so this is impossible by construction.

## Result
Status: theoretical-historical-replay
Expected PnL: ~(discount_bps - 60bp) × notional on 1000 ETH per event (~4.95 ETH / ~$14,850 net at 1% Curve discount and ETH=$3000; ~1 ETH at 60 bp entry threshold)

Atomic flash-loan arb PoC against OETH/ETH Curve pool, with a quote-gated
execution branch and a graceful no-op when the pool is on-peg. Demonstrates
the unique value of having a permissionless on-chain redeem path (vs USDM/
USDY which lack one): the redeem is the natural "arb circuit-closer" that
keeps OETH's Curve price within `[1 - exit_fee, 1]` of ETH.
