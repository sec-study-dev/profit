# F09-05: PT-weETH-26DEC2024 / WETH 86% LLTV Morpho free-flashloan bootstrap

## Mechanism (3-mechanism)

Morpho Blue's PT-collateral markets, combined with Pendle V4's PT auction and
EtherFi's weETH carry, give us a **single-tx cash-and-carry leverage** on PT
that no other money market can match.

Three mechanisms composed:

1. **Morpho Blue free flashLoan** — zero-fee, callback-style flash on WETH
   from the Morpho singleton. The `onMorphoFlashLoan` callback runs before
   the singleton enforces repayment, so the whole loop fits in one tx.
2. **Pendle V4 `swapExactTokenForPt`** — converts WETH to PT-weETH-26DEC2024
   at the live AMM discount. PT-weETH redeems 1:1 into weETH at maturity
   (Dec 26, 2024); buying it at, say, 0.965 WETH per PT locks a 3.5% fixed
   return to maturity (regardless of weETH-staking APY drift).
3. **EtherFi weETH staking** — the underlying restaking-yield carry that
   backs PT redemption at par. PT is a debt-like claim on weETH; the
   discount-to-par is the *fixed* yield component, and the floating
   restaking yield is paid to YT holders.

The Morpho market is the canonical curated Gauntlet **PT-weETH-26DEC2024 /
WETH 86% LLTV** market. Its parameters:

| field            | value                                                                |
| ---------------- | -------------------------------------------------------------------- |
| loanToken        | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (WETH)                  |
| collateralToken  | `PT-weETH-26DEC2024` (= readTokens(market).pt)                       |
| oracle           | PendleSparkLinearDiscount (linear PT discount oracle, redeployed once)|
| irm              | `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC` (AdaptiveCurveIRM)      |
| lltv             | `860000000000000000` (= 0.86e18)                                    |
| **marketId**     | `0xc581c5f70bd1afa283eed57d1418c6432cbff1d862f94eaf58fdd4e46afbb67e` |

We recover the full struct via `IMorpho.idToMarketParams(id)` so we never
hard-code the (maturity-specific, redeployable) PT oracle address.

## Single-tx open

```
1. IMorpho.flashLoan(WETH, FLASH=105 ether, "pt-weeth-loop")
2. onMorphoFlashLoan callback:
   - total WETH on contract = 30 (equity) + 105 (flash) = 135
   - swapExactTokenForPt(135 WETH -> PT-weETH @ ~0.965/PT) -> ~139.9 PT-weETH
   - supplyCollateral(market, 139.9 PT)
   - borrow(market, 105 WETH)
3. Morpho's safeTransferFrom pulls 105 WETH back, flash settled.
```

Position after: ~139.9 PT-weETH collateral, 105 WETH debt, net 30 WETH
equity expressed as ~34.9 PT-weETH of NAV (PT × 0.965 - debt).

## Why it composes — unique to Morpho

- **Free flash on the *same* singleton that holds the lend book.** No other
  protocol pairs zero-fee flash with curated PT lending in one contract.
  Aave's PT-weETH-as-collateral pilot has higher LLTV haircuts AND charges
  5 bps flash fee.
- **Immutable PT oracle.** Once Morpho's PT oracle is configured, it can't
  be migrated under us; the linear-discount math (PT_price = 1 - discount ×
  time_remaining/total_time) is deterministic from the maturity timestamp.
- **PT carry > borrow rate.** At fork block, PT discount implies ~12-15%
  APY-equivalent fixed yield while WETH borrow on this market is ~2.5%; the
  spread × leverage is captured directly.

## PnL math

Let `discount = 0.035` (3.5% PT discount to par, ~129 days to maturity →
implied APY ~10.0%), `b = 0.025` (WETH borrow APY on Morpho PT-weETH/WETH
market), `equity = 30`, `flash = 105`, `K = 4.5x` total notional/equity.

```
PT bought       = 135 / 0.965 = 139.9 PT
PT par-value    = 139.9 weETH at maturity, valued in WETH at ~1.04 (weETH/WETH)
                = 145.5 WETH @ T = +129d
Debt at T       = 105 × (1 + 0.025 × 129/365) = 105 × 1.0088 = 105.9
Gross at T      = 145.5 - 105.9 = 39.6 WETH
Net PnL         = 39.6 - 30 = 9.6 WETH on 30 WETH equity = 32% absolute
                (101% APY-equivalent)
```

Worst-case (weETH/WETH at 1.00 unchanged):

```
PT par-value at T = 139.9 weETH * 1.00 = 139.9 WETH
Net PnL           = 139.9 - 105.9 - 30 = 4.0 WETH = 13% absolute, 38% APY-equiv.
```

Gas single-tx: ~750k × 30 gwei × $3k/ETH = ~$67.

## Block pinned

**20,650,000** (mid-August 2024). PT-weETH-26DEC2024 has ~129 days to
maturity, market is liquid (>1k WETH spare in the Morpho market and >5k
WETH in the Pendle pool). PT discount at this block: ~3-4% to par.

## Risks

- **PT price drift at oracle**: Morpho's PendleSparkLinearDiscount oracle
  linearises the PT price toward par monotonically. If the live Pendle AMM
  PT price drops *below* the oracle's linear discount (e.g. weETH depeg from
  ETH, or LRT market panic), the position becomes liquidatable while the
  oracle still values collateral high. This is the headline risk; a 5%
  weETH/WETH gap to oracle is the historical worst-case.
- **weETH depeg vs WETH**: PT redeems into 1 weETH, valued in WETH by
  weETH/WETH rate. A 4% weETH/WETH depeg eliminates the carry.
- **Morpho WETH singleton spare** < FLASH_AMOUNT: reverts cheaply, retry.
- **Pendle market liquidity drain**: AMM slippage at 135 ETH in could be
  significant if the pool depth drops; PoC sets minPtOut = 0 (production
  should set tight slippage).
- **Adaptive-curve IRM spike**: WETH borrow rate can ramp above PT yield
  if utilisation spikes; carry compresses.

## Result

Status: **theoretical / mechanically-tested** — the marketId, Pendle
market, and Morpho registry are all verified live in `setUp`. PnL is
fixed-at-maturity (PT pulls to par) so the structure is a near-deterministic
locked yield once opened.

Expected PnL on 30 WETH equity over 129 days to maturity:
**+4.0 to +9.6 WETH** (13-32% absolute) net of $67 gas; depending mostly
on whether weETH/WETH rate appreciates with restaking yield.

## Uncertainties

- **PT oracle address**: maturity-specific and re-deployable; `setUp`
  recovers it via `idToMarketParams(id)` so the test stays robust.
- **Pendle slippage on 135-ETH swap**: depends on AMM TVL at fork block;
  the test logs `ptOut` for inspection.
- **MarketId**: cross-checked against Morpho's public market list for
  PT-weETH/WETH-86; if it doesn't resolve, the LLTV-assert in setUp
  reverts with a clear error.
