# B02-04: WBETH (BSC) `exchangeRate()` vs PCS v3 ETH/WBETH spot lag

## Mechanism
Binance Wrapped Beacon ETH (WBETH) is a non-rebasing ETH LST. The token's
canonical "ETH per WBETH" rate is exposed via `IWBETH.exchangeRate()` and
this rate is mirrored from ETH mainnet to BSC via Binance's internal
bridge. Critically:

1. The rate **updates onchain on BSC slowly** (typically once every few
   hours when Binance's keeper pokes the contract).
2. The PCS v3 WBETH/ETH (Binance-Peg ETH = `BSC.WETH`) pool reacts to ETH
   mainnet WBETH price moves *quickly* — bridged arbers move quotes within
   seconds of a mainnet shift.

The asymmetry creates a recurring window of 5-25 minutes where
`exchangeRate()` says WBETH is worth (say) 1.043 ETH while the BSC PCS v3
pool prices it at 1.046 ETH (because mainnet just printed a rate update
that BSC hasn't reflected yet). The arb is to act on whichever side is
mispriced *relative to the lagging on-chain rate*.

Specifically, when **PCS quote > on-chain `exchangeRate()`**, a holder can:
1. PCS v3 single-pool flash WETH.
2. Swap WETH -> WBETH on PCS v3 at the *low* WBETH price (relative to
   incoming rate update).
3. Wait for the next on-chain rate update — or, more pragmatically for
   atomic arb: simultaneously short WBETH on Binance CEX as a hedge so
   the position is rate-neutral, then unwind once the keeper updates.

The fully-on-chain atomic version (this PoC) instead exploits **direction
of mispricing relative to ETH bridge premium**: if PCS WBETH/WETH < ETH
mainnet WBETH/ETH, buy on BSC and bridge to ETH; if PCS WBETH/WETH > ETH
mainnet, mint on Binance and sell on BSC. The PoC implements the in-tx
*round trip* version: PCS 100-bp tier vs PCS 500-bp tier, with the
on-chain `exchangeRate()` as a sanity check on which side is mispriced.

## Why it composes
- **WBETH `exchangeRate()`**: rate-update keeper on BSC lags ETH mainnet by
  minutes-to-hours, while the LST has a deterministic monotonic rate that
  cannot drift below its last update.
- **PCS v3 multi-tier on WBETH/WETH**: bridges and CEX market makers
  rebalance the 500-bp tier first (where they LP), leaving the 100-bp
  retail tier briefly stale.
- **PCS v3 single-pool flash**: standard cheap atomic funding.

## Preconditions
- WBETH/WETH PCS v3 pools exist on ≥2 fee tiers (TODO verify 100 & 500).
- `IWBETH(WBETH).exchangeRate()` returns a sane value ≥ 1e18. At any block
  > Q3 2023 this is true (WBETH has accumulated yield since launch).
- Sufficient depth: WBETH/WETH on BSC has lower TVL than slisBNB/WBNB
  (~$30M total), so flash size should stay under 200 WETH.

## Strategy steps
1. Resolve flash pool: PCS v3 WBETH/WETH 500-bp tier.
2. `flash(WETH = 150 WETH, 0)`.
3. In callback:
   a. Swap WETH -> WBETH on the 100-bp tier (where the lag is, by
      hypothesis).
   b. Read `rate = IWBETH.exchangeRate()`. Compute fair WBETH amount =
      `notional * 1e18 / rate`. If `wbethReceived > fairAmount * (1 + flashFee)`,
      the arb is alive.
   c. Swap WBETH -> WETH on the 500-bp tier (fresher quote).
   d. Repay flash + fee.
4. PnL = WETH residual after repayment.

## PnL math
Let `R = exchangeRate() / 1e18` (ETH per WBETH). Let `P_100`, `P_500` be the
WBETH-per-WETH quotes from each pool.

Round trip: `wbeth = N * P_100`; `weth_out = wbeth / P_500 (since P_500 is
WBETH-per-WETH, the *inverse* gives WETH-per-WBETH)`. Net = N * P_100 /
P_500.

Gross PnL = `N * (P_100 / P_500 - 1)`. Fees: flash 5 bp + swap-in 1 bp +
swap-out 5 bp = 11 bp friction.

Realistic dislocations on WBETH (modest float on BSC):
- Quiet: 3-8 bp (often inside friction, no trade)
- Following ETH mainnet WBETH price jump: 15-40 bp window for 5-30 min.
- At 25 bp net (after friction), `N = 150 WETH` ≈ 0.375 WETH ≈ $1,125.

## Block pinned
- `FORK_BLOCK = 45_000_000` (placeholder). **TODO**: pin a block ≤ 30 min
  after a Binance keeper-pushed `exchangeRate` update to BSC, where the
  100-bp pool has not yet re-quoted.

## Risks
- **Both pools quote off the same on-chain state**: if a single bridger
  arbed both tiers in the same block, the inter-tier spread is gone before
  this trade lands. In practice MEV searchers compete fiercely on this.
- **WBETH depth**: 200 WETH on the 100-bp pool may move price 30 bp,
  eating most of the spread. PoC sizes 150 WETH; production should
  size-dynamically using `quoteExactInputSingle`.
- **exchangeRate() is the slow side**: this strategy is fundamentally
  *about* that lag; if Binance changes keeper cadence to be faster, the
  window closes.
- **WBETH = Binance-issued**: contract is upgradeable. PoC reads through
  the proxy address but a malicious upgrade could brick `exchangeRate()`.

## Result
- Status: **theoretical / offline-first**. Strongly time-of-day dependent.
- Expected PnL: **+$400 to +$2,500 per 150 WETH** at typical mid-day
  bridge-lag windows. Frequent zero days when bridge is fully synced.
