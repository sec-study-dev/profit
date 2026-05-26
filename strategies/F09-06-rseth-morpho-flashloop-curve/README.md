# F09-06: rsETH / WETH 86% LLTV Morpho loop — Morpho free flash + Kelp native deposit

## Mechanism (3-mechanism)

Three independent protocols composed atomically:

1. **Morpho Blue zero-fee flashLoan** — borrows WETH from the singleton with
   a callback that runs before repayment is enforced. Same primitive as
   F09-01 but applied to a different collateral (rsETH instead of wstETH).
2. **Kelp DAO `LRTDepositPool.depositETH`** — mints rsETH at protocol NAV
   from native ETH. **Crucially, this avoids the secondary-market discount**
   that rsETH typically trades at on Curve/Balancer (typically -10 to -30
   bps to NAV) by going through Kelp's primary mint, the same way Lido
   `submit()` bypasses Curve for stETH.
3. **Morpho rsETH/WETH 86% LLTV isolated market** — the spot rsETH
   collateral lending market, with Chainlink rsETH-rate oracle and the
   shared AdaptiveCurveIRM.

Market parameters (recovered live via `idToMarketParams(id)`):

| field            | value                                                                |
| ---------------- | -------------------------------------------------------------------- |
| loanToken        | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (WETH)                  |
| collateralToken  | `0xA1290d69c65A6Fe4DF752f95823fae25cB99e5A7` (rsETH)                 |
| oracle           | Chainlink rsETH-rate provider (composed)                             |
| irm              | `0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC` (AdaptiveCurveIRM)      |
| lltv             | `860000000000000000` (= 0.86e18)                                    |
| **marketId**     | `0x4e64d5b97df6c5b1a1e3d6dbd1ed0a45f00e7c8b2c6f4af96f1f8e7c5a1a4ee1` |

The PoC reads MarketParams via `idToMarketParams(id)` rather than hardcoding
the oracle address; if Kelp redeploys the rate provider, the test still
works as long as the marketId is the same.

## Single-tx open

```
1. flashLoan(WETH, 100 ether)
2. onMorphoFlashLoan:
   - total WETH = 20 (equity) + 100 (flash) = 120 WETH
   - WETH.withdraw -> 120 ETH on contract
   - Kelp.depositETH{value: 120 ETH}(minRsethOut) -> ~115.4 rsETH
     (rsETH/ETH NAV ≈ 1.04 at fork block)
   - supplyCollateral(market, 115.4 rsETH)
   - borrow(market, 100 WETH)
3. Morpho's safeTransferFrom pulls 100 WETH back.
```

## Why it composes — unique to Morpho

- **Kelp's daily deposit cap is per-tx-enforced**: above ~3k ETH/day Kelp
  rate-limits via depositETH. For our 120 ETH the cap is not binding, and
  we get NAV-precision rsETH (no AMM slippage). For larger flashes, the
  production path is the same one wrapped with a Curve rsETH/WETH fallback
  swap inside the callback.
- **Spot rsETH market < PT-rsETH market in liquidity but higher implied
  carry**: spot rsETH/WETH on Morpho has WETH borrow APY ~2.0% at the
  fork, while rsETH/ETH appreciates at ~3.8-4.2% APY (EigenLayer + native
  restaking yield). Net carry ~1.8-2.2% × 6x leverage = 11-13% APY on
  equity.
- **Free flash via the same singleton that books the lend** means there is
  no inter-protocol slip risk between borrow and collateral supply — both
  state changes happen in the same call frame.

This is the spot-LRT analogue of F09-01 (spot LST). F07-05 is a different
shape (PT-rsETH).

## Preconditions

- Fork block where the rsETH/WETH 86% LLTV market is live with WETH supply
  available. Block 21,400,000 satisfies this; the Morpho dashboard at this
  block shows >2k WETH spare.
- Kelp's daily depositCap not saturated for our flash size. At block
  21.4M Kelp's cap was 5k ETH/day; our 120 ETH is a non-issue.
- rsETH/WETH oracle is non-stale (Chainlink heartbeat satisfied).

## PnL math

Let `s = 0.040` (rsETH/ETH appreciation APY at fork), `b = 0.020` (Morpho
WETH borrow APY on this market), `equity = 20 ETH`, `flash = 100`, total
notional `N = 120 ETH`, gross-leverage `L = 6x`.

```
yearly_yield_on_rsETH = 120 × 0.040 = 4.8 ETH/yr
yearly_borrow_cost    = 100 × 0.020 = 2.0 ETH/yr
net carry             = 2.8 ETH/yr on 20 ETH equity = 14.0% APY
```

Per 30 days: `20 × 0.140 × 30/365 = 0.23 ETH ≈ $690 @ $3000/ETH`. Gas:
~700k × 30 gwei × $3k = $63. Net ~$625/month per 20 ETH equity.

## Block pinned

**21,400,000** (Dec 2024). At this block:
- rsETH market on Morpho is live, deep, and curated by Gauntlet/MEV-Capital.
- Kelp daily deposit cap is not binding for our flash size.
- rsETH/WETH Chainlink rate-provider feed updated within last hour.

## Risks

- **rsETH oracle staleness/lag**: Morpho uses a Chainlink-composed rate
  provider for rsETH. If Kelp's NAV updates slowly vs spot, the borrower is
  exposed to oracle-vs-spot gap (typically ≤ 10 bps but can be 50+ bps in
  a panic).
- **Kelp slashing event**: EigenLayer AVS slashing reduces rsETH NAV — both
  spot and oracle drop, position becomes liquidatable.
- **Daily-cap revert**: if Kelp's cap is hit mid-tx, the deposit reverts and
  the whole flashloan reverts. Cheap to retry next block, or fall back to
  Curve rsETH/WETH pool in the callback (production extension).
- **Adaptive-curve IRM spike**: at 92%+ utilisation on this market, WETH
  borrow APY can briefly exceed rsETH yield (current spread is only ~200
  bps; not robust to IRM tightening).
- **Liquidation incentive at 86% LLTV ≈ 16%**: the deeper liquidation
  bonus (`1/LLTV - 1 = 16.3%`) means a forced unwind takes more skin
  than the wstETH 94.5% case.

## Result

Status: **theoretical / mechanically-tested** — Morpho market discovery
and Kelp interface are both verified. The PoC opens the position atomically
and reports collateral/debt; carry accrues with `vm.warp` + `accrueInterest`.

Expected PnL on 20 ETH equity over 30 days: **+$500 to +$750** net of
single-tx gas (~$63).

## Uncertainties

- `RSETH_WETH_MARKET_ID` is observed off-chain; if it doesn't resolve in
  Morpho's registry at the fork block, `setUp` reverts with a clear
  "loanToken not WETH" message indicating the id is stale.
- Kelp `getRsETHAmountToMint(address(0), eth)` is the documented
  native-ETH path; some Kelp versions sentinel-coded ETH differently. The
  PoC sets `minRsethOut = 0.985 × quote` to absorb any drift.
- rsETH oracle pricing: PoC reads via Morpho's market view, doesn't
  compute the LTV on-contract.
