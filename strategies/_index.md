# Strategies Index (Wave 3 aggregate)

This index is generated from `strategies/F*/README.md` files. It is the
sortable master list of every PoC produced by Wave 2.

- **68** strategies across **17** families (F01..F17).
- Status taxonomy: `theoretical` (built from docs, not fork-replayed),
  `mechanically-reproducible` (on-chain calls exercised end-to-end on the
  pinned fork block, but full PnL accrual not asserted),
  `theoretical-historical-replay` (parameterised to a specific past depeg /
  cap-open / vote round, requires archive RPC to surface), and
  `empirically-validated` (cash leg directly fork-replayed; reserved here for
  strategies that exercise both legs and assert a strict positive PnL).
- `forge` was **not** installed in the build env; statuses are therefore
  Wave-2 self-reports. Verification belongs to the user (see REPORT.md §5).

---

## Section A — Strategy table

Sorted by family then by NN. `Block` is the fork-pin from each README's
`## Block pinned` section. `Expected PnL` is copied verbatim from the
README's `## Result` block (truncated). The full text lives in the per-
strategy README. The midpoint heuristic used for the top-N tables in
Section C is described in the footnote.

| ID     | Family | Title                                                                 | Block        | Type         | Status                      | Expected PnL (verbatim)                                              |
| ------ | ------ | --------------------------------------------------------------------- | ------------ | ------------ | --------------------------- | -------------------------------------------------------------------- |
| F01-01 | F01    | wstETH eMode loop on Aave v3                                          | 20_900_000   | positional   | theoretical                 | +0.85% to +1.05% / 30d on 100 ETH (~$2.5-3.0k)                        |
| F01-02 | F01    | wstETH / WETH Morpho Blue loop bootstrapped by Morpho flashloan       | 21_400_000   | positional   | theoretical                 | +0.9% to +1.1% / 30d on 100 ETH (~$2.3-2.8k)                          |
| F01-03 | F01    | rETH on Aave v3 eMode, one-shot via Aave flashLoanSimple              | 21_000_000   | positional   | theoretical                 | +0.45% to +0.65% / 30d on 100 ETH (~$1.1-1.6k)                        |
| F01-04 | F01    | cbETH eMode loop on Aave v3 (historical inverted-rate regime)         | 17_500_000   | positional   | theoretical-historical-replay | +1.0% to +1.4% / 30d on 100 ETH (~$2.0-2.8k)                        |
| F02-01 | F02    | weETH leveraged restake via Morpho flashloan loop                     | 19_200_000   | points       | theoretical                 | Cash +$10-22k/yr; Cash+points +$100-500k/yr on 100 ETH                |
| F02-02 | F02    | ezETH points farming via Pendle YT (point-decoupling loop)            | 19_400_000   | points       | theoretical                 | Base +$140-400k / 120d (point conversion dominates)                   |
| F02-03 | F02    | pufETH stacked re-hypothecation (Karak / Symbiotic re-deposit)        | 19_800_000   | points       | theoretical                 | +$8-15k cash; +$250-500k with full airdrop stack / yr                 |
| F02-04 | F02    | weETH → Aave V3 eMode → borrow ETH → restake (pure points loop)       | 19_500_000   | points       | theoretical                 | Cash +$3-10k/yr; full point stack +$100k-$1M/yr                       |
| F03-01 | F03    | Curve stETH/ETH depeg arb with Lido withdrawal-queue redemption       | 17_560_000   | positional   | theoretical-historical-replay | +$5-8k per 1000 ETH @ 15-25bps; +$60k peak depeg                    |
| F03-02 | F03    | ezETH/WETH Balancer depeg arb — Renzo April 2024 event                | 19_690_000   | atomic       | theoretical-historical-replay | +$10-90k per 200 WETH at peak depeg                                 |
| F03-03 | F03    | rETH Balancer rate-provider lag vs Curve spot                         | 20_400_500   | atomic       | theoretical                 | +$50 to +$500 per 500 WETH, spikes to +$2k                            |
| F03-04 | F03    | Multi-LST triangular arb — Curve stETH × Curve rETH × wstETH wrap     | 17_560_000   | atomic       | theoretical                 | +$200 to +$3,000 per 500 WETH                                         |
| F04-01 | F04    | DssFlash + PSM + Curve 3pool USDC depeg arbitrage (atomic)            | 16_818_900   | atomic       | theoretical-historical-replay | Spread * notional - gas, sized to remain in money                   |
| F04-02 | F04    | sDAI as Spark collateral, DAI-borrow re-stake loop                    | 19_500_000   | positional   | theoretical                 | leverage>2.5x, positive net DAI / 30d (DSR-Spark spread)              |
| F04-03 | F04    | sUSDS leveraged via DAI borrow on Spark (Sky Savings Rate spread)     | 21_500_000   | positional   | theoretical                 | leverage>2.3x, positive net / 60d at positive SSR-Spark spread        |
| F04-04 | F04    | DssFlash + PSM + Aave USDC supply-rate spike arb (atomic)             | 20_900_000   | atomic       | theoretical                 | Structurally zero-fee path; profit = supply APY × notional × t       |
| F05-01 | F05    | wstETH/crvUSD LLAMMA band-cross arbitrage                             | 19_643_500   | atomic       | theoretical-historical-replay | +$200 to +$1,500 per opp; +$1-5k at uncontested descents            |
| F05-02 | F05    | WBTC/crvUSD LLAMMA soft-liquidation harvest                           | 19_643_500   | atomic       | theoretical-historical-replay | +$150-1,200 contested; +$1-4k uncontested; $25-70k/yr               |
| F05-03 | F05    | wstETH -> crvUSD leveraged borrow loop                                | 20_650_000   | positional   | theoretical                 | -1% to +4% APY (building block for F16)                               |
| F05-04 | F05    | crvUSD peg arbitrage via Maker DSS-Flash + Curve                      | 18_500_000   | atomic       | theoretical-historical-replay | +$1-60k per opp; $30-150k/yr sole searcher                          |
| F06-01 | F06    | LUSD redemption arbitrage funded by Maker DSS flashmint               | 14_400_000   | atomic       | theoretical-historical-replay | +5-15bps net / turn; +50-150bps at stress; $5-15k / $10M turn       |
| F06-02 | F06    | Liquity v1 Stability Pool yield + ETH gain compounding loop           | 17_950_000   | positional   | theoretical-historical-replay | Calm 1-3 bps/cycle; Crisis 50-200 bps/cluster                       |
| F06-03 | F06    | Liquity v2 BOLD redemption sniper (lowest-interest-rate trove)        | 21_500_000   | atomic       | theoretical                 | +15-25 bps / turn; +250 bps under 300bp depeg                         |
| F06-04 | F06    | Leveraged BOLD borrow loop against wstETH on Liquity v2               | 21_500_000   | positional   | theoretical                 | +$1.5-5k/yr on 10 wstETH @ 5x leverage                                |
| F07-01 | F07    | PT-sUSDe cash-and-carry, leveraged on Morpho                          | 20_200_000   | positional   | theoretical                 | +25% to +40% / 90d on $1M @ K≈6                                       |
| F07-02 | F07    | PT-weETH leveraged buy on Morpho (ETH-side carry)                     | 20_650_000   | positional   | theoretical                 | +40 to +48 WETH / 180d on 100 WETH @ K≈7-8 (~$100-120k)               |
| F07-03 | F07    | YT-weETH points speculation                                           | 20_650_000   | points       | theoretical                 | Base +30x principal; EV +200%; downside -40%                          |
| F07-04 | F07    | PT/SY redemption arbitrage near maturity                              | 20_661_000   | atomic       | theoretical                 | +$900 to +$4,000 / 3d on $1M USDC                                     |
| F08-01 | F08    | sUSDe leveraged supply on Morpho with USDC debt (loop)                | 19_800_000   | positional   | theoretical                 | +4.1% / 30d on $1M USDe @ K≈4.83 (~$40k net)                          |
| F08-02 | F08    | USDe peg arbitrage via Balancer flash + dual Curve pools (atomic)     | 19_500_000   | atomic       | theoretical                 | +$500-1,200 / 1M USDT at 15bp edge                                    |
| F08-03 | F08    | PT-sUSDe leveraged buy on Morpho with USDC flashloan                  | 19_950_000   | positional   | theoretical                 | +11.9% / 3.4 months on $100k @ ~5x leverage (annualised ~44%)         |
| F08-04 | F08    | sUSDe stablecoin e-mode loop on Aave v3                               | 20_400_000   | positional   | theoretical                 | +3.0% / 30d on $1M USDe @ K≈4.91 (~$30k)                              |
| F09-01 | F09    | wstETH/WETH 94.5% LLTV Morpho loop — single-tx bootstrap via Curve    | 21_400_000   | positional   | mechanically-reproducible   | +0.45-0.55 ETH / 30d on 50 ETH (~$1.3-1.65k)                          |
| F09-02 | F09    | sUSDe / DAI 91.5% LLTV Morpho loop — free-flashloan bootstrap         | 21_400_000   | positional   | mechanically-reproducible   | +$15-50k / 30d on $400k equity                                        |
| F09-03 | F09    | MetaMorpho idle-liquidity capture — supply before reallocation        | 21_400_000   | positional   | mechanically-reproducible   | +$4-5.5k / 30d on $1M @ post-allocation 5-7% APY                      |
| F09-04 | F09    | Morpho cross-market rate-arb — supply high-rate, borrow low-rate      | 21_400_000   | atomic       | mechanically-reproducible   | +$500-2,500 / 7-30d on $1M before convergence                         |
| F10-01 | F10    | GHO mint + Balancer GHO/USDC carry                                    | 20_500_000   | positional   | theoretical                 | +1.4-1.6% / 30d on 1M USDC (~$14-16k)                                 |
| F10-02 | F10    | Spark sDAI/DAI eMode leveraged loop                                   | 19_800_000   | positional   | theoretical                 | +3,000-3,500 DAI / 30d on 1M DAI                                      |
| F10-03 | F10    | Spark DAI borrow + sDAI / aDAI rate arb                               | 19_500_000   | positional   | theoretical                 | +1,600-2,000 USD / 30d on 1M USDC                                     |
| F10-04 | F10    | GHO mint with stkAAVE discount + sDAI/USDS carry                      | 21_500_000   | positional   | theoretical                 | +$750-900 / 30d on 100k USDC + 1k stkAAVE (~5% APR)                   |
| F11-01 | F11    | Compound v3 USDC Comet — leveraged WETH loop                          | 20_500_000   | positional   | theoretical                 | -0.4 to -0.5% / 30d flat; +13% / 30d on +3% ETH drift                 |
| F11-02 | F11    | Fluid wstETH/ETH smart-collateral leveraged loop                      | 21_000_000   | positional   | theoretical                 | +1.0-1.4% / 30d on 100 ETH @ K~10                                     |
| F11-03 | F11    | Euler v2 EVC batch — same-asset cross-vault rate arb                  | 21_200_000   | positional   | theoretical                 | $40-120/mo per $1M (50-150 bps spread)                                |
| F11-04 | F11    | Cross-MM Comet ↔ Aave USDC supply-rate arbitrage                      | 20_700_000   | positional   | theoretical                 | ~$25 / 30d on $200k borrow (scales linearly)                          |
| F12-01 | F12    | Convex Booster LP loop on Curve frxETH/ETH (boosted CRV+CVX+FXS)      | 19_643_500   | positional   | theoretical                 | +$110-130 / 14d / 100 LP gross                                        |
| F12-02 | F12    | vlCVX lock + Votium MultiMerkleStash bribe-claim simulation           | 19_643_500   | vote/bribe   | theoretical                 | +$800-1,800 / 14d round on 10k CVX                                    |
| F12-03 | F12    | Convex stETH/ETH triple-reward stack (CRV+CVX+LDO)                    | 19_643_500   | positional   | theoretical                 | +$300-400 / 14d / 50 LP                                               |
| F12-04 | F12    | Curve gauge-weight vote snipe via veCRV                               | 19_643_500   | vote/bribe   | theoretical                 | +$500-3,500 / round on 100k CRV / 4y lock                             |
| F13-01 | F13    | UniV3 wstETH/WETH flashloan + Balancer rate-provider arb              | 20_900_000   | atomic       | theoretical                 | -$50 to +$300 / 1000 WETH (stale-window sensitive)                    |
| F13-02 | F13    | Balancer rETH rate-provider lag vs UniV3 rETH/WETH 0.01%              | 21_500_000   | atomic       | theoretical                 | +$100 to +$2,000 / 500 WETH                                           |
| F13-03 | F13    | Balancer wstETH/WETH ComposableStable LP — double-yield carry         | 20_900_000   | positional   | mechanically-reproducible   | +1.8-2.3% APR net on 100 WETH                                         |
| F13-04 | F13    | UniV3 wstETH/WETH 0.01% concentrated narrow-range LP                  | 20_900_000   | positional   | mechanically-reproducible   | 10-25% APR net on 20 ETH (benign markets)                             |
| F14-01 | F14    | sETH -> sUSD atomic vs ETH -> USDC Uniswap triangular arbitrage       | 17_500_000   | atomic       | theoretical                 | notional × \|drift_bps − 50bp\| (live-pair gated)                     |
| F14-02 | F14    | sUSD/3pool depeg arb via Synthetix atomic exchange                    | 16_818_900   | atomic       | theoretical-historical-replay | sUSD depeg - 85 bp; profitable at SVB-class events                  |
| F14-03 | F14    | sBTC <-> sETH <-> sUSD synth triangular arbitrage                     | 17_500_000   | atomic       | theoretical                 | combined clamp deviation > ~130 bp (oracle-tail)                      |
| F14-04 | F14    | Atomic exchange immediately after Chainlink oracle update             | 16_900_000   | atomic       | theoretical                 | Condition-dependent on update event                                   |
| F15-01 | F15    | stETH direct EigenLayer deposit vs Renzo ezETH alternative            | 19_650_000   | points       | empirically-validated (entry) | LRT/native +/- $5-10k on 100 stETH split (block-dependent)         |
| F15-02 | F15    | EigenLayer cap-race — be first into the new deposit window            | 19_500_021   | points       | mechanically-reproducible   | ~$1.5k / yr / 100 ETH (keeper infra)                                  |
| F15-03 | F15    | EigenLayer 7-day withdrawal-queue exit + secondary market             | 19_700_000   | positional   | theoretical                 | Break-even hold-to-maturity; +$1.5k/cycle with hypothetical secondary |
| F15-04 | F15    | Native EigenLayer restake + Symbiotic dual-stack                      | 20_400_000   | points       | theoretical                 | Bull +$123k/yr (35%); Base +$50-70k; Bear +$10k on 100 wstETH         |
| F16-01 | F16    | LUSD 0%-borrow trove + Aave USDC supply carry                         | 20_400_000   | positional   | theoretical                 | +2-3% APR on LUSD notional (ex opportunity cost)                      |
| F16-02 | F16    | GHO mint vs crvUSD borrow — cross-CDP rate basis                      | 20_500_000   | positional   | theoretical                 | ~$4.6k / yr on $200k debt (2.3% APR rebate)                           |
| F16-03 | F16    | DSS Flashmint triangular DAI -> GHO -> crvUSD -> DAI                  | 20_500_000   | atomic       | theoretical                 | +5-15 bps net / $1M typical; +100 bps tail                            |
| F16-04 | F16    | GHO mint -> LUSD Stability Pool carry                                 | 20_500_000   | positional   | theoretical                 | +$1.5-2k / 30d on $100k GHO (~18-25% APR, LQTY-priced)                |
| F17-01 | F17    | USDM rebase carry via Curve crvUSD/USDM pool                          | 20_500_000   | positional   | mechanically-reproducible   | strictly-more-units rebase signal (rate ~5% APY)                      |
| F17-02 | F17    | syrupUSDC vs sUSDS carry-stack rotation                               | 20_600_000   | positional   | mechanically-reproducible   | >1% APY entry spread; positive post-warp share value                  |
| F17-03 | F17    | OETH/ETH Curve depeg + atomic 1:1 redeem arb                          | 20_400_000   | atomic       | mechanically-reproducible   | discount > 60 bps gate, profit = (discount - exit_fee) × notional     |
| F17-04 | F17    | OUSD rebase passthrough via Aave supply (with wOUSD wrapper variant)  | 20_500_000   | positional   | theoretical                 | 2x-leverage if integration exists; diagnostic otherwise               |

---

## Section B — Family roll-up

### F01 — LST looping (4 strategies)
**Description (STRATEGY_IDS.md):** Leverage looping of stETH / wstETH / rETH / cbETH / sfrxETH via Aave / Morpho.
**Key idea:** Extract the spread between LST staking yield + supply APR and the variable WETH borrow rate, amplified by 5-14× via correlated-asset eMode collateral factors.
**Strategies:** F01-01, F01-02, F01-03, F01-04

### F02 — LRT looping & restake (4 strategies)
**Description:** EtherFi / Renzo / Kelp / Puffer leveraged restaking and points farming.
**Key idea:** Same loop mechanics as F01 but pointed at LRTs, where the *real* payoff is the multi-protocol point stack (EtherFi loyalty + EigenLayer + LRT-native + EIGEN/REZ/PUFFER/SYMB airdrops) — the cash leg is just paying for time on the leverage.
**Strategies:** F02-01, F02-02, F02-03, F02-04

### F03 — LST/LRT basis & peg (4 strategies)
**Description:** Curve / Balancer peg arbitrage between LSTs/LRTs and ETH, withdrawal queues.
**Key idea:** Atomic flashloan-driven trades that exploit (a) AMM depegs vs the LST's redeem path, and (b) lag between a Balancer rate-provider cache and the live exchange-rate function.
**Strategies:** F03-01, F03-02, F03-03, F03-04

### F04 — Maker DSR / sDAI / sUSDS (4 strategies)
**Description:** DSR-anchored yield, PSM hops, sDAI / sUSDS leveraged via flash mint.
**Key idea:** Maker's free flashmint (DssFlash) + zero-fee PSM is the only fully-fee-free leg in DeFi; the family stacks it with Spark borrows and Aave supply to capture rate divergences.
**Strategies:** F04-01, F04-02, F04-03, F04-04

### F05 — crvUSD LLAMMA (4 strategies)
**Description:** Soft-liquidation arbitrage and leveraged crvUSD borrows against LSTs.
**Key idea:** LLAMMA's `price_oracle()` EMA lags spot on fast moves — searchers buy collateral cheap from the in-band liquidating range, and (separately) flashmint DAI to arb crvUSD's peg via Curve.
**Strategies:** F05-01, F05-02, F05-03, F05-04

### F06 — Liquity v1/v2 (LUSD / BOLD) (4 strategies)
**Description:** Stability pool yield, redemption arbitrage, BOLD interest-rate dynamics.
**Key idea:** Liquity redemptions are atomic, 1:1 against the lowest-CR (v1) or lowest-rate (v2) trove — combined with a Maker flashmint that funds the redemption, this is one of the rare zero-capital alpha sources during peg stress.
**Strategies:** F06-01, F06-02, F06-03, F06-04

### F07 — Pendle PT / YT (4 strategies)
**Description:** PT leveraged buy, YT yield speculation, SY composition with LST/LRT/stables.
**Key idea:** PT is sold at a discount to underlying; looping it on Morpho captures the pull-to-par. YT decouples the points stream from the principal — the highest-asymmetry leg in this whole research corpus.
**Strategies:** F07-01, F07-02, F07-03, F07-04

### F08 — Ethena USDe / sUSDe (4 strategies)
**Description:** sUSDe carry, Pendle PT-sUSDe, looped sUSDe on Morpho/Aave.
**Key idea:** sUSDe APY is internet-bond-style funded by perp basis; looping it 4-5× on Morpho/Aave with USDC debt is the cleanest stable-stable rate-spread carry in the corpus.
**Strategies:** F08-01, F08-02, F08-03, F08-04

### F09 — Morpho Blue isolated markets (4 strategies)
**Description:** Custom market loops, flashloan-bootstrap, idle-liquidity capture.
**Key idea:** Morpho's free flashloan (callback model, no premium) enables one-tx loop bootstrap; the per-market isolation lets curators set 94.5% LLTV on assets Aave can't touch.
**Strategies:** F09-01, F09-02, F09-03, F09-04

### F10 — Aave v3 / Spark / GHO (4 strategies)
**Description:** E-mode loops, GHO mint-and-deploy, isolation-mode farming.
**Key idea:** GHO is variable-rate-minted at a discount for stkAAVE holders; combined with Aave eMode and Spark's DSR-pegged DAI, this is the on-chain stablecoin-rate basis surface.
**Strategies:** F10-01, F10-02, F10-03, F10-04

### F11 — Compound v3 + Fluid + Euler (4 strategies)
**Description:** Cross-money-market rate arbitrage and isolated-vault composability.
**Key idea:** USDC supply rates diverge by 50-170 bps across Comet / Aave / Fluid / Euler vaults; the Euler v2 EVC enables a same-tx multi-vault batch that no other MM can match.
**Strategies:** F11-01, F11-02, F11-03, F11-04

### F12 — Curve + Convex + bribes (4 strategies)
**Description:** vlCVX vote-directed bribes, Votium / Hidden-Hand claim loops, gauge ecosystem.
**Key idea:** vlCVX abstracts the veCRV vote market — bribe income on a 14-day round basis is the highest-IRR purely-positional return in the corpus, gated only on willing-to-lock duration.
**Strategies:** F12-01, F12-02, F12-03, F12-04

### F13 — Balancer / Uniswap v3 LP (4 strategies)
**Description:** Concentrated liquidity + boosted-pool stacking with LST primary tokens.
**Key idea:** Balancer's rate-provider cache (24h heartbeat) goes stale relative to live LST exchange rates — UniV3 flash + 2-leg swap captures the gap atomically.
**Strategies:** F13-01, F13-02, F13-03, F13-04

### F14 — Synthetix atomic + sUSD (4 strategies)
**Description:** sUSD / sETH atomic-swap arbitrage and synth-as-collateral composites.
**Key idea:** Synthetix's atomic-exchange "fair value" exit ramp clamps to the worse-of-two oracles; when one oracle is stale, that clamp is the arbitrageur's bid.
**Strategies:** F14-01, F14-02, F14-03, F14-04

### F15 — EigenLayer native restake (4 strategies)
**Description:** Direct EigenLayer strategy deposits, AVS rewards, LRT-vs-native comparisons.
**Key idea:** Native restake captures the same EIGEN-points stream as the LRTs but without the wrapper-token depeg risk; cap-races and 7-day withdrawal queues are exploitable secondary markets.
**Strategies:** F15-01, F15-02, F15-03, F15-04

### F16 — Cross-CDP basis (4 strategies)
**Description:** Multi-CDP loops mixing GHO / crvUSD / DAI / LUSD as base debt.
**Key idea:** Every CDP system prices its own borrow rate independently; the basis between GHO, crvUSD, DAI and LUSD borrow rates is sometimes 100+ bps and tradable via DssFlash triangulation.
**Strategies:** F16-01, F16-02, F16-03, F16-04

### F17 — Yield-bearing stable carry (4 strategies)
**Description:** USDM / USDY / OUSD / syrupUSDC carry stacks vs sDAI / sUSDS baseline.
**Key idea:** Each yield-bearing stable expresses its yield differently (rebase, share-price, wrapper) and trades at different Curve discounts — pure-stable rotations capture both the APY differential and the entry-discount.
**Strategies:** F17-01, F17-02, F17-03, F17-04

---

## Section C — Filter views (top-N)

**Sorting heuristic.** Wave-2 PnL estimates are expressed in many units
(USD, ETH, % APR, % over horizon, point-airdrop value). To produce a single
comparable number we use the following normalisation, computed manually
per row:

1. If the estimate is given as a USD range over a horizon, take the
   range midpoint and rescale to a 30-day window. Example:
   `+$15-50k / 30d` → midpoint $32.5k.
2. If the estimate is given as a percentage over a horizon on a stated
   notional, multiply midpoint% × notional and rescale to 30 days. Example:
   `+4.1% / 30d on $1M` → $41k.
3. Points-based strategies use the **base case (one airdrop realised)**
   number, not the bull tail.
4. Strategies whose PnL is per-opportunity (atomic depeg arbs) use
   per-opportunity midpoint × an assumed 1 opportunity / 30 days unless the
   README states a different opportunity frequency, in which case the
   stated rate is used.
5. ETH-denominated estimates are converted at $2500 / ETH (the price
   floor used throughout Wave-2 READMEs).

These heuristics are **lossy** — the ranking is for navigation, not for
deciding what to deploy. The real PnL is the README plus the fork-replay.

### Top 10 by expected gross 30-day PnL (USD-normalised)

| Rank | ID     | Title                                                           | 30d-norm USD     | Type       |
| ---- | ------ | --------------------------------------------------------------- | ---------------- | ---------- |
| 1    | F02-02 | ezETH points farming via Pendle YT                              | ~$67.5k          | points     |
| 2    | F07-03 | YT-weETH points speculation                                     | ~$50k+           | points     |
| 3    | F02-03 | pufETH stacked re-hypothecation                                 | ~$30k            | points     |
| 4    | F08-01 | sUSDe leveraged supply on Morpho with USDC debt                 | ~$40k            | positional |
| 5    | F09-02 | sUSDe / DAI 91.5% LLTV Morpho loop                              | ~$32.5k          | positional |
| 6    | F02-04 | weETH eMode → restake (point stack)                             | ~$25k+ (base)    | points     |
| 7    | F08-04 | sUSDe stablecoin e-mode loop on Aave v3                         | ~$30k            | positional |
| 8    | F15-04 | Native EigenLayer + Symbiotic dual-stack                        | ~$5-10k / mo     | points     |
| 9    | F10-01 | GHO mint + Balancer GHO/USDC carry                              | ~$15k            | positional |
| 10   | F07-01 | PT-sUSDe cash-and-carry on Morpho                               | ~$108k / 90d → ~$36k normalised | positional |

(Rows that are points-dominated have been placed using the README's
**base / median airdrop realised** estimate. Bull-tail outcomes for
F02-02 / F02-03 / F02-04 / F07-03 would all dominate this list, but
they depend on TGE pricing not knowable on-chain.)

### Top 10 atomic strategies

| Rank | ID     | Title                                                           | Best estimate    |
| ---- | ------ | --------------------------------------------------------------- | ---------------- |
| 1    | F03-02 | ezETH/WETH Balancer depeg arb (Renzo April 2024)                | +$10-90k / event |
| 2    | F05-04 | crvUSD peg arbitrage via Maker DSS-Flash + Curve                | +$1-60k / event  |
| 3    | F06-01 | LUSD redemption arbitrage funded by Maker DSS flashmint         | +5-15 bps × $10M ≈ $7.5k / turn |
| 4    | F08-02 | USDe peg arbitrage Balancer flash + dual Curve pools            | +$500-1,200 / $1M @ 15bp |
| 5    | F07-04 | PT/SY redemption arbitrage near maturity                        | +$900-4,000 / 3d / $1M |
| 6    | F05-01 | wstETH/crvUSD LLAMMA band-cross arbitrage                       | +$1-5k uncontested descent |
| 7    | F03-04 | Multi-LST triangular arb (Curve × Curve × wstETH wrap)          | +$200-3,000 / 500 WETH |
| 8    | F16-03 | DSS Flashmint triangular DAI → GHO → crvUSD → DAI               | +5-15 bps × $1M  |
| 9    | F13-02 | Balancer rETH rate-provider lag vs UniV3 0.01%                  | +$100-2,000 / 500 WETH |
| 10   | F17-03 | OETH/ETH Curve depeg + atomic 1:1 redeem arb                    | (discount − exit_fee) × notional |

### Top 10 positional strategies (carry-style)

| Rank | ID     | Title                                                           | 30d-norm USD     |
| ---- | ------ | --------------------------------------------------------------- | ---------------- |
| 1    | F08-01 | sUSDe leveraged supply on Morpho with USDC debt                 | ~$40k / $1M      |
| 2    | F07-01 | PT-sUSDe cash-and-carry on Morpho                               | ~$36k / $1M      |
| 3    | F09-02 | sUSDe / DAI 91.5% LLTV Morpho loop                              | ~$32.5k / $400k  |
| 4    | F08-04 | sUSDe stablecoin e-mode loop on Aave v3                         | ~$30k / $1M      |
| 5    | F08-03 | PT-sUSDe leveraged buy on Morpho with USDC flashloan            | ~$10k / 30d / $100k → +$1k normalised, but ann. ~44% |
| 6    | F10-01 | GHO mint + Balancer GHO/USDC carry                              | ~$15k / $1M      |
| 7    | F11-02 | Fluid wstETH/ETH smart-collateral loop                          | ~$7.5k / 100 ETH |
| 8    | F10-02 | Spark sDAI/DAI eMode leveraged loop                             | ~$3.25k / 1M DAI |
| 9    | F13-04 | UniV3 wstETH/WETH narrow-range LP                               | ~$1k / 20 ETH    |
| 10   | F09-03 | MetaMorpho idle-liquidity capture                               | ~$4.75k / $1M    |

*Ranks here are best-effort: many positional strategies are scale-free
(carry × notional), so the absolute USD figure depends on how much
capital you can deploy. Use the README's stated notional as the base
case and rescale to your size.*

