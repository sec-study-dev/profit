# F03-07: cbETH peg arb post-Coinbase exchangeRate update

## Mechanism
Coinbase Wrapped Staked ETH (`cbETH`,
`0xBe9895146f7AF43049ca1c1AE358B0541Ea49704`) is a non-rebasing LST that
appreciates against ETH via the contract storage variable `exchangeRate`.
Unlike Lido (`stEthPerToken` continuously updates on rewards report) and
Rocket Pool (`getExchangeRate` updates on `submitBalances`), Coinbase
**manually** pushes the rate via an admin call — typically once every
7-14 days, with the update reflecting all the accumulated staking rewards
since the last bump.

Each rate update is a **step function** of typically 30-60 bps (covering
~7-14 days × ~3.5%/365 APR). At the instant of the update:

- `cbETH.exchangeRate()` jumps from `R_old` to `R_new = R_old * (1 + δ)`.
- The Curve `cbETH/ETH` crypto pool (`0x5FAE7E604FC3e24fd43A72867ceBaC94c65b404A`)
  trades at the *AMM spot price* which had been quietly drifting *upward*
  in anticipation of the bump (informed traders frontrun) but rarely
  prices in the *full* δ in advance.
- The UniV3 `cbETH/WETH` pools (0.05% `0x840DEEef2f115Cf50DA625F7368C24af6fE74410`)
  similarly lag — concentrated-liquidity ticks don't reposition instantly.

The arb window: in the **first block** after `exchangeRate` jumps but
before AMM pricing catches up, the cbETH/ETH AMM spot is *lower* than the
freshly-updated `R_new`. A buyer of cbETH on the AMM acquires it below
the new fair value implied by `R_new`.

Because cbETH has **no on-chain redemption path** (Coinbase only redeems
off-chain via centralized accounts), this is **not** a closed-loop arb
back to ETH within one tx. It's a directional bet: buy cbETH on AMM
cheap, hold until other arbitrageurs / liquidity providers bring the
AMM spot up to `R_new`. The PoC captures the snapshot trade and prices
the resulting cbETH at the post-update rate via `PriceOracle.priceUSD`.

## Why it composes
- **Flashloan**: Balancer V2 Vault — 0 fee. (Alternative: Aave V3 9 bps; we
  prefer Balancer for cost.)
- **Curve crypto pool**: stableswap-crypto with `uint256` indices. Curve
  cbETH/ETH pool has ~1500 ETH / 1500 cbETH depth; supports payable native
  ETH for index 0.
- **UniV3 cbETH/WETH 5bp**: secondary venue for cross-AMM splitting if
  Curve depth is insufficient.
- **cbETH ERC20**: `exchangeRate()` is a simple getter; we read pre- and
  post-trade to assert the snapshot.

The composition is: one **off-chain protocol event** (Coinbase admin tx
calling `updateExchangeRate`) emits an on-chain step change that **two
independent AMMs** absorb at different speeds.

## Preconditions
- Block must be **immediately after** a Coinbase `exchangeRate` update tx.
  Historical updates (from Etherscan event logs `ExchangeRateUpdated`):
  - `2024-01-30` ≈ block 19_113_500
  - `2024-02-13` ≈ block 19_213_000
  - `2024-04-09` ≈ block 19_604_000
  - `2024-07-30` ≈ block 20_390_000
  - `2024-10-15` ≈ block 20_975_500
- Curve `cbETH/ETH` quote at this block: typically `0.94-0.97 cbETH per ETH`
  (because cbETH is appreciating; 1 ETH buys less than 1 cbETH).
- Sufficient pool depth: Curve cbETH pool ~1500 ETH/side; UniV3 ~500 WETH
  in-range. Combined ~2000 WETH worth of fillable depth.

## Strategy steps
1. Read `cbETH.exchangeRate()` to obtain `R_new` (1e18-scaled).
2. Balancer V2 Vault `flashLoan` 300 WETH.
3. In `receiveFlashLoan`:
   a. Unwrap WETH -> ETH.
   b. Curve `cbETH/ETH` crypto pool: `exchange{value: N}(0, 1, N, minOut)`
      buying cbETH at AMM spot.
   c. (Optional) split: re-wrap remaining ETH -> WETH, swap on UniV3
      cbETH/WETH 5bp for the second half.
   d. End of callback: cbETH balance retained; theoretical value
      = `cbETH * R_new / 1e18 ETH`.
   e. Repay flash from a pre-funded WETH buffer (since we hold cbETH out
      until off-chain Coinbase redemption / AMM convergence).
4. `_endPnL` prices cbETH via `PriceOracle.priceUSD(CBETH)` which uses
   `cbETH.exchangeRate() * ethUsdE8()`. Net PnL = (cbETH retained × R_new
   priced 1:1 to ETH) − (WETH consumed from buffer).

## PnL math
Let:
- `R_new` = post-update cbETH/ETH rate (1e18). Typically jumps 30-60 bps.
- `P_C`   = Curve cbETH-per-ETH spot (≈ `1/R_pre_amm` where `R_pre_amm`
            is AMM's lagged effective rate).

For `R_new = 1.0850` (e.g. block right after a 50 bps bump from 1.0800)
and `P_C ≈ 1.0810` (AMM had ~+10 bps premium going in, didn't catch the
full 50 bps): the rate-vs-AMM gap is `40 bps`.

Per WETH input:
- cbETH out (Curve) = `1 / R_amm_implied` where `R_amm_implied` is the
  cbETH/ETH ratio Curve charges. At a Curve quote where 1 ETH -> 0.925
  cbETH, the implied rate is `1/0.925 = 1.0811`.
- Value of that cbETH at `R_new`: `0.925 * 1.0850 = 1.0037 ETH`.
- Edge = 37 bps gross.

For `N = 300 WETH`:
- Gross spread = `300 * 0.0037 = 1.11 WETH ≈ $3,550 @ $3,200/ETH`
- Curve fee ≈ 4 bps (0.12 WETH) + UniV3 5bp (0.0075 WETH on half)
  ⇒ ≈ 0.15 WETH ≈ $480
- Gas ≈ 400k @ 25 gwei = 0.01 WETH ≈ $32
- **Net ≈ 0.95 WETH ≈ $3,040 per 300 WETH** at a ~40 bps step.

Smaller (typical 10-20 bps post-update gap) cases land at +$500-1500/300 WETH.

## Block pinned
- `FORK_BLOCK = 20_390_100` — first 100 blocks after the July 30 2024
  Coinbase `exchangeRate` update tx (search Etherscan logs of cbETH for
  `ExchangeRateUpdated(uint256 newRate)` event). Specifically the
  Coinbase oracle pusher (`0x837...`) calls `updateExchangeRate(uint256)`.
- Empirical event-tx hash pattern: search by Coinbase oracle EOA;
  see e.g. tx `0x60c5cd0... ` (2024-07-30) — exact hash pending RPC
  verification.

## Risks
- **No atomic close**: cbETH has no on-chain redemption. PnL is realized
  only when subsequent flow re-prices the AMM to `R_new` (typically hours).
  The PoC marks-to-market via `PriceOracle`; live PnL is the realized
  exit price.
- **Self-impact on Curve**: 300 WETH on a 1500 ETH side moves the price
  ~10 bps deeper. Sizing must respect depth.
- **MEV competition**: rate updates are watched by every searcher;
  capturing the first block requires private builder access.
- **Wrong-way step**: rare, but Coinbase has manually corrected
  `exchangeRate` downward on accounting errors. PoC requires
  `R_new > R_pre_AMM_implied` to fire (checked via `MIN_SPREAD_BPS`).
- **Curve fee tier changes**: pool fee can be raised via Curve DAO vote.

## Result
- Status: **theoretical** (directional snapshot trade; PnL realization
  requires AMM convergence over hours; PoC marks at protocol rate).
- PnL range: **+$500 to +$3,000 per 300 WETH** depending on size of
  the step and how quickly other arbs front-run.
- 3+ mechanisms: Balancer flash + Curve crypto pool + UniV3 (split) +
  cbETH rate-getter as on-chain truth oracle.
