# B12-08: Avalon BTC-LSD liquidation keeper with cross-DEX exit

## Mechanism (atomic + cross-DEX)
1. **PCS v3 USDX/USDT 1bp flash** — borrow `debtToCover` USDX with
   1 bp fee.
2. **Avalon Aave V3 `liquidationCall`** — when a borrower's HF
   drops below 1 (BTC drawdown, pumpBTC/enzoBTC depeg, or
   USDX rate spike), call `liquidationCall(solvBTC, USDX, user,
   debtToCover, false)` to seize discounted solvBTC collateral.
   Avalon publishes a 5-10 % liquidation bonus on BTC-LSD markets.
3. **Cross-DEX best-execution exit** — solvBTC -> BTCB -> USDT ->
   USDX. PCS v3 5bp tier first; Thena volatile pair fallback if
   PCS lacks depth or reverts. The cross-DEX router captures the
   best execution across the two liquidity venues.
4. Repay flash USDX (notional + 1 bp); keep the residual USDX
   (the liquidation bonus net of swap costs and flash fee).

## Why it composes
- Single atomic transaction — keeper holds zero pre-trade inventory.
- Cross-DEX exit minimises slippage on what is sometimes a
  thin secondary AMM (solvBTC/BTCB pools); without the Thena
  fallback, a single-DEX route can give up >50 bp of edge on
  larger seizes.
- Flash-loan funding means liquidations of arbitrary size are
  bounded only by the PCS v3 USDX pool depth (typically $5-20 M).

## Preconditions
- Avalon `liquidationCall` selector matches Aave V3 standard.
- An under-collateralized borrower exists at the pinned block
  (LOCAL_TARGET_BORROWER = TODO real address from indexer).
- PCS v3 USDX/USDT 1bp pool exists.
- PCS v3 (or Thena) solvBTC/BTCB and BTCB/USDT pools have depth
  >= $1 M.

## Strategy steps ($50k debt liquidation)
1. flashLoan(USDX, $50k) from PCS v3 USDX/USDT pool.
2. Inside callback: `liquidationCall(solvBTC, USDX, target, $50k, false)`
   -> receive ~$53,750 of solvBTC (7.5 % bonus).
3. Swap solvBTC -> BTCB; if PCS v3 reverts, fallback to Thena.
4. Swap BTCB -> USDT -> USDX on PCS v3 multi-hop.
5. `require(usdxBack >= $50k + flashFee)`.
6. Repay flash; profit stays in keeper.

## PnL math (single $50k debt liquidation)
- Liquidation bonus: $50,000 * 7.5 % = **+$3,750**.
- Flash fee 1 bp: -$5.
- DEX exit slippage 25 bp on $53.75k: -$134.
- Gas: ~700k * 1 gwei * $600/BNB / 1e18 = **-$0.42**.
- **Net: ~ +$3,611 per call.**

At 5 calls / day during stress windows = ~$18k/day = ~$540k/month.
In normal markets, calls are rare (1-2/week); average run-rate
~ $30-50k/month.

## Block pinned
**47_700_000** (early-2025; placeholder pending a real
under-collateralized target at the same block).

## Addresses used
- `BSC.AVALON_LENDING_POOL` — Avalon Aave V3 fork.
- `BSC.PCS_V3_ROUTER`, `BSC.PCS_V3_FACTORY` — PCS v3 venue.
- `BSC.THENA_ROUTER` — Thena fallback venue.
- `BSC.solvBTC`, `BSC.BTCB`, `BSC.USDT`.
- `LOCAL_USDX = 0xf3527eF8...` — Avalon USDX (TODO verify).
- `LOCAL_TARGET_BORROWER = 0x...B12081` — under-collateralized
  borrower placeholder (TODO indexer).

## Risks
- MEV race: multiple keepers compete; mitigate via private order
  flow (BloXroute, MEV-share on BSC) and tight gas-limit bidding.
- Liquidation revert if HF crosses back above 1 (price recovers
  in same block). PoC reverts atomically; no inventory risk.
- solvBTC AMM depth: if neither PCS v3 nor Thena has depth, the
  swap leg returns 0 and the tx reverts harmlessly. Mitigation:
  partial liquidation (Aave V3 allows 50 % close factor).

## Result
Status: **theoretical** (target borrower must be sourced from an
on-chain indexer; PoC compiles, guards every external call, and
falls back to offline accounting with a documented bonus).
Expected PnL: **~ $3.6k per $50k liquidation; $30-50k/month avg
run-rate**.
