# B01-08: WBETH (bridged Beacon ETH) → Venus → borrow peg-ETH → re-mint loop

## Mechanism
The first **ETH-correlated** B01 strategy. WBETH is Binance's wrapped
beacon ETH (non-rebasing share token, bridged onto BSC via the BNB
Bridge). Same recursive shape as the BNB-LST loops but the carry comes
from the **ETH stake APY vs. BSC peg-ETH borrow APR** spread, not the
BNB carry.

1. **WBETH (Binance staked ETH)** — peg-ETH → WBETH at the internal
   `exchangeRate()`. Stake yield accrues to that rate.
2. **Venus Core pool** — supply WBETH (`vWBETH`), borrow peg-ETH (`vETH`).
   Both are ETH-correlated assets; an eMode-style market group (if
   listed) bumps the collateral factor for ETH-pair markets.
3. **Recycle** — borrowed peg-ETH is re-minted into WBETH and re-supplied.

## Why a separate ETH-LSD slot in B01 family
- The four existing B01 PoCs are all **BNB-correlated**: their PnL is
  driven by BNB price and BNB IRMs. B01-08 brings ETH-correlated
  leverage into the family — a portfolio-level diversifier.
- BSC's peg-ETH borrow markets are **shallower** than mainnet's ETH
  borrow markets. The Venus vETH IRM kink sits at low utilization
  (~70 %), and the slope is mild → borrow APR for the first few %
  utilization is well below ETH stake APY. Equivalent mainnet trades
  (wstETH/Aave) have been arbed down to ~30 bps spread; on BSC the
  same trade can carry 80–150 bps because fewer farmers are in the pool.
- WBETH has a tight peg vs. ETH (both are claims on staked ETH;
  arbitrage via the BNB Bridge keeps it within ±10 bps), so SAFETY_BPS
  can be higher (97 % vs. 95 % on the BNB loops).

## Strategy steps
1. Start with 30 ETH equivalent of peg-ETH on BSC (~$90 k notional).
2. For N=4 iterations:
   - Mint WBETH from peg-ETH via WBETH contract (`mint(uint256)` or
     `wrap(uint256)` — we try both ABI variants).
   - Supply WBETH into vWBETH.
   - Borrow peg-ETH from vETH at 97 % of available liquidity.
3. Hold 30 days. Yield = WBETH exchange-rate drift (ETH staking) minus
   vETH borrow interest, levered ~3×.
4. Re-mark WBETH oracle to current `exchangeRate × $3000` and report.

## PnL math (indicative)
- ETH stake APY (via WBETH): ~3.0 %.
- BSC peg-ETH borrow APR (Venus, low utilization): ~1.2 %.
- 4 iterations at CF=0.75 × 0.97 (eMode boost) = 0.728 → leverage
  L ≈ 1 + 0.728 + 0.53 + 0.387 + 0.281 ≈ **2.93×**.
- Net APY: 2.93 × 3.0 − 1.93 × 1.2 = 8.79 − 2.32 = **+6.47 %**.
- 30-day yield: 6.47 × 30/365 ≈ **+0.53 % on principal** ≈ +0.16 ETH on
  30 ETH ≈ **+$480 absolute**.
- Gas: 4 enterMarkets/mint/borrow cycles ≈ 1.4M gas → ~$0.80.

## Block pinned
**42_000_000**. Need Venus vWBETH and vETH listings live; eMode listing
is a bonus, the loop runs without it at lower leverage.

## Addresses used / TODOs
- `BSC.WBETH` = `0xa2E3356610840701BDf5611a53974510Ae27E2e1`.
- `BSC.WETH`  = `0x2170Ed0880ac9A755fd29B2688956BD959F933F8` (peg-ETH).
- `LOCAL_VWBETH` — Venus WBETH market token. **TODO verify**.
- `LOCAL_VETH`   — Venus peg-ETH market token. **TODO verify** (may be
  named vETH or vWETH depending on Venus naming convention).
- WBETH mint ABI on BSC is unclear; PoC tries `mint(uint256)` and
  `wrap(uint256)` via low-level `call`. Once the canonical BSC ABI is
  known, hard-code it.

## Risks
- **Peg dislocation**: WBETH/peg-ETH can detach during BNB-Bridge
  freezes. Mitigation: SAFETY_BPS=97 % still leaves 3 % headroom; if the
  bridge halts, the loop should be unwound on PCS v3 WBETH/ETH pool
  (typical slippage 20–50 bps).
- **Venus eMode unavailable**: collateral factor drops from 0.75 to
  ~0.70; PnL drops to ~+5.5 % gross / +0.13 ETH / 30 days. Still
  positive.
- **vETH IRM jump**: borrow APR is low only while utilization is low.
  At >80 % utilization the kink quadruples APR, flipping the carry
  negative. Monitor and unwind.

## Result
Status: **theoretical**. Expected: **+0.13–0.18 ETH per 30 ETH / 30
days (~+$400–550)**, ETH-correlated rather than BNB-correlated — a
natural portfolio diversifier vs. B01-01..07.
