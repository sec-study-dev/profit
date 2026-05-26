# F03-01: Curve stETH/ETH depeg arb with Lido withdrawal-queue redemption

## Mechanism
stETH is *intended* to track ETH 1:1, but stETH/ETH trades in the Curve
`stETH/ETH` pool (`0xDC24316b9AE028F1497c275EB9192a3Ea0f67022`) at a market
price that historically diverged sharply during liquidity crises:

- **June 2022 (Three Arrows Capital / Celsius unwind)**: stETH/ETH spot
  bottomed near **0.935 stETH = 1 ETH** (Curve pool 70/30 imbalanced) before
  Shanghai upgrade enabled native unstaking — there was *no redemption path*
  back to ETH at the time, only forced AMM exits.
- **May 2023 onwards**: post-Shanghai, the Lido withdrawal queue
  (`0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1`) accepts stETH and pays
  exactly 1 stETH = 1 ETH after the queue is processed (~1-5 days).

The arbitrage is: borrow ETH via Balancer V2 flashloan (zero fee), buy stETH
cheap on Curve (e.g. 0.998 stETH per ETH ratio implies ~20 bps discount),
submit a withdrawal request to Lido — the NFT entitles you to the full ETH
1:1. PnL is the spread minus AMM fees.

The "atomic" part of the trade is the cheap-side fill: lock in the spread
inside one tx. The redemption itself is *not* atomic (queue delay) so the PoC
computes **theoretical PnL** assuming 1:1 redemption value of the resulting
withdrawal NFT.

## Why it composes
- **Flashloan**: Balancer V2 Vault flashloans ETH/WETH at 0 fee (no premium).
- **Peg deviation**: Curve `stETH/ETH` pool's stableswap math + imbalanced
  balances => occasional sub-1 stETH/ETH ratio when sellers dominate.
- **Redemption path**: Lido withdrawal queue (`requestWithdrawals`) finalises
  at 1 stETH = 1 ETH. The NFT can also be sold on secondary AMMs
  (`unstETH NFT Curve pool` etc.) at a discount if the holder wants immediacy.

## Preconditions
- Block must have non-trivial stETH/ETH discount on Curve. Two natural pins:
  - **15310000** (≈ June 18 2022, peak depeg) — pre-Shanghai, no redemption
    available; PoC values the stETH leg at *Curve spot*, not 1:1.
  - **17560000** (≈ July 4 2023) — post-Shanghai with healthy queue and
    residual minor (~5-20 bps) discounts.
- Sufficient Curve pool depth (>20k ETH each side) to push 1000+ ETH through
  without >1% slippage.
- Balancer Vault holds enough WETH to flash (it does — billions in TVL).

## Strategy steps
1. Balancer V2 Vault `flashLoan` 1000 WETH into the strategy contract.
2. Inside `receiveFlashLoan`: unwrap WETH -> ETH.
3. Curve `exchange(0, 1, 1000e18, minOut)` where index 0 = ETH, 1 = stETH.
   Receives `~1000 / spotPrice` stETH (typically ~1002-1005 stETH at
   modern small discounts; ~1070+ in 2022 peak).
4. Approve `LIDO_WITHDRAWAL_QUEUE` for the received stETH and call
   `requestWithdrawals([stEthAmount], address(this))`. Receives unstETH NFT.
5. (Theoretical) when NFT finalises in 1-5 days, claim 1:1 ETH.
6. Wrap returned ETH -> WETH, repay flash 1000 WETH to Vault.
7. PnL accounting: track stETH balance growth (priced at peg) minus
   the flashed WETH out (priced at 1:1). The wstETH-NFT receivable is
   reflected by *retaining* the stETH balance at end of tx and pricing it
   at 1:1 via `PriceOracle.priceUSD(STETH) == ETH_USD`.

## PnL math
Let `R = Curve stETH/ETH spot` (stETH per ETH). For `N` ETH flashed:
- `stETH_out = N / R` (Curve, less ~4 bps fee)
- Redeemed ETH (theoretical 1:1) = `stETH_out`
- Gross PnL = `stETH_out - N = N * (1/R - 1)`
- Balancer flash fee = **0**
- Curve fee = ~4 bps of notional
- Gas ≈ 350k @ 25 gwei => ~0.009 ETH

For `R = 0.998` (20 bps discount), `N = 1000 ETH`:
- Gross = `1000 * (1.002004 - 1) = 2.004 ETH ≈ $7,500 @ $3,750/ETH`
- Net ≈ `2.004 - 0.40 (curve) - 0.009 (gas) ≈ 1.60 ETH ≈ $6,000`

For the **3AC depeg** at `R = 0.94`:
- Gross = `1000 * 0.0638 ≈ 63.8 ETH ≈ $76,500 @ $1,200/ETH`
- However, **redemption did not exist pre-Shanghai**, so this profit only
  realises if you (a) market-make the stETH back out at a tighter spread or
  (b) wait many months for Shanghai. Not atomic. PoC pins post-Shanghai.

## Block pinned
- `FORK_BLOCK = 17560000` (July 4 2023) — first real period with Lido
  withdrawals live. Curve stETH/ETH spot at this block: ~0.9985 (≈ 15 bps).
- Alternative test: `FORK_BLOCK = 15310000` (3AC peak depeg) to demonstrate
  the gross spread, but redemption leg is unavailable.
- Historical Curve stETH/ETH discount data: Dune query 1144700 / DeFiLlama
  Lido peg dashboard.
- Reference depeg event tx (not arb, just market dislocation):
  `0x77ee...` (June 13 2022 mass stETH liquidations). No verified arb tx
  hash at this exact block.

## Risks
- **Slippage**: Curve stableswap is concentrated near peg; a 1000 ETH order
  moves the price ~5-10 bps and eats half the spread. Strategy must size
  to remain inside the pre-trade discount.
- **Sandwich**: pre-Shanghai, sandwich bots front-ran stETH buys aggressively.
- **Queue delay**: withdrawal NFT finalisation takes 1-5 days. The trade
  carries duration risk that stETH ↔ ETH price changes between request and
  claim. The PoC assumes 1:1 redemption (theoretical).
- **Pool re-pegs while NFT pending**: if discount widens during the wait,
  better to have sold spot than wait the queue (but spot was the side that
  got bought from cheap, so opportunity cost only).

## Result
- Status: **theoretical** (cheap-leg buy is atomic and provable on-fork;
  redemption leg is asynchronous and modelled as 1:1).
- PnL range: **+$5k to +$8k per 1000 ETH** at 15-25 bps discounts (post-2023);
  **+$60k+ per 1000 ETH** at June 2022 peak depeg but with no atomic exit.
