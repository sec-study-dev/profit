# Strategies Index (Wave 4 aggregate)

This index is generated from `strategies/F*/README.md` files. It is the
sortable master list of every PoC produced by Waves 2 and 4.

- **147** strategies across **18** families (F01..F18).
- Wave 1 = repository skeleton; Wave 2 = 17 family agents producing 68
  baseline PoCs; Wave 3 = aggregator (this file's predecessor); Wave 4 =
  17 family-deepening agents adding 73 strategies (FXX-05..09) **plus** 1
  new family agent (F18) adding 6 tri-protocol stacks. Total Wave 4
  delta: +79 strategies and +TODO verifications on prior PoCs.
- **F18 is a NEW family** added in Wave 4. Every F18 strategy explicitly
  composes ≥3 distinct DeFi protocol mechanisms in a single trade or
  position — the family stress-tests true tri-protocol composability.
- Status taxonomy: `theoretical` (built from docs, not fork-replayed),
  `mechanically-reproducible` / `mechanically-tested` / `mechanically-
  demonstrated` (on-chain calls exercised end-to-end on the pinned fork
  block, but full PnL accrual not asserted),
  `theoretical-historical-replay` (parameterised to a specific past
  depeg / cap-open / vote round, requires archive RPC to surface),
  `structurally-reproducible` / `structurally-ready` (Liquity-style: uses
  view-stable contracts and is ready to replay subject to
  address-resolution), and
  `empirically-validated` (cash leg directly fork-replayed; reserved for
  strategies that exercise both legs and assert a strict positive PnL).
- `forge` was **not** installed in the build env in any wave; statuses are
  therefore self-reports by the agents that wrote them. Verification
  belongs to the user (see REPORT.md §5).
- The Wave 4 fix to `foundry.toml` (`test = "strategies"`) means that
  `forge test` now actually discovers the PoCs under `strategies/`; in
  Wave 3 this discovery was silently broken.

---

## Section A — Strategy table

Sorted by family then by NN. `Block` is the fork-pin from each README's
`## Block pinned` section. `Type` is one of
`atomic` (single-tx, flashloan-bootstrapped),
`positional` (multi-block carry / leveraged loop / LP),
`points` (LRT loyalty + EigenLayer + airdrop speculation),
`vote-bribe` (veCRV / vlCVX / vlAURA / vePENDLE governance economics),
`liquidation` (soft-liq harvest, redemption sniper).
`Expected PnL` is paraphrased from the README's `## Result` block; the
full text lives in the per-strategy README.

| ID     | Family | Title                                                                                  | Block      | Type       | Status                          | Expected PnL (summary)                                              |
| ------ | ------ | -------------------------------------------------------------------------------------- | ---------- | ---------- | ------------------------------- | ------------------------------------------------------------------- |
| F01-01 | F01    | wstETH eMode loop on Aave v3                                                           | 20_900_000 | positional | theoretical                     | +0.85% to +1.05% / 30d on 100 ETH (~$2.5-3.0k)                       |
| F01-02 | F01    | wstETH / WETH Morpho Blue loop bootstrapped by Morpho flashloan                        | 21_400_000 | positional | theoretical                     | +0.9% to +1.1% / 30d on 100 ETH (~$2.3-2.8k)                         |
| F01-03 | F01    | rETH on Aave v3 eMode, one-shot via Aave flashLoanSimple                               | 21_000_000 | atomic     | theoretical                     | +0.45% to +0.65% / 30d on 100 ETH (~$1.1-1.6k)                       |
| F01-04 | F01    | cbETH eMode loop on Aave v3 (historical inverted-rate regime)                          | 17_500_000 | positional | theoretical-historical-replay   | +1.0% to +1.4% / 30d on 100 ETH (~$2.0-2.8k)                         |
| F01-05 | F01    | sfrxETH on Fraxlend FRAX pair leveraged loop                                           | 20_650_000 | positional | theoretical                     | +0.3% to +0.5% / 30d on 100 ETH at K≈3.3                             |
| F01-06 | F01    | wstETH on Compound v3 WETH Comet — leveraged loop                                      | 20_800_000 | positional | theoretical                     | +0.7% to +0.9% / 30d on 100 ETH (~$1.7-2.3k)                         |
| F01-07 | F01    | rETH on Spark, borrow DAI, redeploy to sDAI for DSR carry (3-mech)                     | 19_700_000 | positional | theoretical                     | +0.2% to +0.3% / 30d (≈ +0.2 ETH on 100 ETH)                         |
| F01-08 | F01    | wstETH Aave eMode loop + Pendle PT-wstETH fixed-rate hedge                              | 21_400_000 | positional | theoretical                     | +0.55% to +0.60% / 30d on 100 ETH (lower variance vs F01-02)         |
| F02-01 | F02    | weETH leveraged restake via Morpho flashloan loop                                       | 19_200_000 | points     | theoretical                     | Cash +$10-22k/yr; Cash+points +$100-500k/yr on 100 ETH                |
| F02-02 | F02    | ezETH points farming via Pendle YT (point-decoupling loop)                              | 19_400_000 | points     | theoretical                     | Base +$140-400k / 120d; bull +$1M+; bear -$120-210k                  |
| F02-03 | F02    | pufETH stacked re-hypothecation (Karak / Symbiotic re-deposit)                          | 19_800_000 | points     | theoretical                     | +$8-15k cash; +$250-500k full airdrop / yr                           |
| F02-04 | F02    | weETH → Aave V3 eMode → borrow ETH → restake (pure points loop)                         | 19_500_000 | points     | theoretical                     | Cash +$3-10k/yr; full point stack +$100k-$1M/yr                      |
| F02-05 | F02    | rsETH triple-points stack (Kelp + Karak + Pendle YT) + Morpho flashloan bootstrap       | 19_750_000 | points     | theoretical                     | Cash -$26k; conservative points +$50-80k; bull +$200k+               |
| F02-06 | F02    | pufETH triple-stack — Puffer + Symbiotic DefaultCollateral + Aave eMode                 | 20_100_000 | points     | theoretical                     | Cash +$5-10k; base points +$200-300k; bull +$550k+                   |
| F02-07 | F02    | weETH PT/YT split — sell PT for cash, keep YT, leverage via Morpho flashloan            | 19_400_000 | points     | theoretical                     | Conservative +$120k; base +$500-700k; bear -$234k                    |
| F02-08 | F02    | weETH leveraged on Fluid weETH-ETH<>wstETH smart-collateral vault                       | 21_200_000 | points     | theoretical                     | Cash +$15-25k; base points +$50-80k; bull +$140-250k                 |
| F03-01 | F03    | Curve stETH/ETH depeg arb with Lido withdrawal-queue redemption                          | 17_560_000 | atomic     | theoretical-historical-replay   | +$5-8k per 1000 ETH @ 15-25bps; +$60k peak depeg                     |
| F03-02 | F03    | ezETH/WETH Balancer depeg arb — Renzo April 2024 event                                   | 19_690_000 | atomic     | theoretical-historical-replay   | +$10-90k per 200 WETH at peak depeg                                  |
| F03-03 | F03    | rETH Balancer rate-provider lag vs Curve spot                                            | 20_400_500 | atomic     | theoretical                     | +$50 to +$500 per 500 WETH; spikes to +$2k                           |
| F03-04 | F03    | Multi-LST triangular arb — Curve stETH × Curve rETH × wstETH wrap                        | 17_560_000 | atomic     | theoretical                     | +$200 to +$3,000 per 500 WETH                                        |
| F03-05 | F03    | wstETH wrap-path triangular arb — Curve × Lido wrap × UniV3 (4-mech)                     | 17_560_000 | atomic     | theoretical                     | +$1,000 to +$4,000 per 500 WETH @ 10-30 bps Curve discount           |
| F03-06 | F03    | Multi-LRT triangular depeg — ezETH × weETH × rsETH cross-pool basis (4-mech)             | 19_690_000 | atomic     | theoretical-historical-replay   | +$30k to +$85k per 200 WETH at depeg peak                            |
| F03-07 | F03    | cbETH peg arb post-Coinbase exchangeRate update                                          | 20_390_100 | atomic     | theoretical                     | +$500 to +$3,000 per 300 WETH                                        |
| F03-08 | F03    | frxETH/sfrxETH ERC-4626 rate-provider mismatch arb (4-mech)                              | 21_300_000 | atomic     | theoretical                     | +$500 to +$5,000 per 1000 WETH @ 5-20 bps drift                      |
| F03-09 | F03    | weETH post-Pectra depeg — Curve × UniV3 × EtherFi flash redemption arb (4-mech)          | 22_431_500 | atomic     | theoretical-historical-replay   | +$20k to +$60k per 800 WETH at depeg low                             |
| F04-01 | F04    | DssFlash + PSM + Curve 3pool USDC depeg arbitrage (atomic)                               | 16_818_900 | atomic     | theoretical-historical-replay   | Spread × notional − gas; ~$15k gross on 5M DAI @ 30 bp depeg         |
| F04-02 | F04    | sDAI as Spark collateral, DAI-borrow re-stake loop                                       | 19_500_000 | positional | theoretical                     | Leverage > 2.5×, positive net DAI / 30d at DSR-Spark spread          |
| F04-03 | F04    | sUSDS leveraged via DAI borrow on Spark (Sky Savings Rate spread)                        | 21_500_000 | positional | theoretical                     | Leverage > 2.3×, positive net / 60d at positive SSR-Spark spread     |
| F04-04 | F04    | DssFlash + PSM + Aave USDC supply-rate spike arb (atomic, zero-fee)                      | 20_900_000 | atomic     | theoretical                     | Structurally zero-fee path; profit = supply APY × notional × t       |
| F04-05 | F04    | DaiUsds round-trip + sUSDS slippage probe (cost-basis baseline)                          | 21_500_000 | positional | theoretical                     | ~+1% on 60-day SSR sub-test; cost basis ~0 on round-trip             |
| F04-06 | F04    | sDAI → Morpho sDAI/USDC → Curve 3pool recursive loop (3-mech)                            | 21_500_000 | positional | theoretical                     | Leverage > 2.5× on Morpho; positive 30d DAI growth at DSR>borrow     |
| F04-07 | F04    | DssFlash + LUSD-Curve + Liquity redemption — cross-CDP atomic arb (3-mech)               | 19_200_000 | atomic     | theoretical-historical-replay   | ~$45k on 2M DAI flash; ~$22k after wider slippage                    |
| F04-08 | F04    | sDAI → Spark → USDC borrow → Curve 3pool recycle (3-mech)                                 | 21_500_000 | positional | theoretical                     | Leverage > 2.2×; ~29% on-equity APY at pinned block                  |
| F05-01 | F05    | wstETH/crvUSD LLAMMA band-cross arbitrage                                                 | 19_643_500 | atomic     | theoretical-historical-replay   | +$200 to +$1,500 per opp; +$1-5k uncontested descent                 |
| F05-02 | F05    | WBTC/crvUSD LLAMMA soft-liquidation harvest                                               | 19_643_500 | liquidation| theoretical-historical-replay   | +$150-1,200 contested; +$1-4k uncontested; $25-70k/yr                |
| F05-03 | F05    | wstETH → crvUSD leveraged borrow loop                                                     | 20_650_000 | positional | theoretical                     | -1% to +4% APY (cross-CDP building block)                            |
| F05-04 | F05    | crvUSD peg arbitrage via Maker DSS-Flash + Curve                                          | 18_500_000 | atomic     | theoretical-historical-replay   | +$1-60k per opp; $30-150k/yr sole searcher                           |
| F05-05 | F05    | sfrxETH/crvUSD leverage loop                                                              | 20_650_000 | positional | theoretical                     | +$650 to +$1,200 / 30d on $250k notional                             |
| F05-06 | F05    | tBTC/crvUSD LLAMMA soft-liquidation harvest                                                | 21_000_000 | liquidation| theoretical                     | -$300 to +$2,400 per shot on $300k notional                          |
| F05-07 | F05    | crvUSD (WETH-LLAMMA) → sUSDe Morpho recursive carry (3-mech)                              | 21_300_000 | positional | theoretical                     | +$2,000 to +$4,500 / 30d on $510k WETH principal                     |
| F05-08 | F05    | WETH/crvUSD LLAMMA → Curve crvUSD/USDC LP → Convex booster (3-mech)                       | 21_400_000 | positional | theoretical                     | +$50 to +$400 / 14d on $510k WETH (thin margin, continuous rebal)    |
| F06-01 | F06    | LUSD redemption arbitrage funded by Maker DSS flashmint                                   | 14_400_000 | atomic     | theoretical-historical-replay   | +5-15 bps; +50-150 bps stress; $5-15k / $10M turn                    |
| F06-02 | F06    | Liquity v1 Stability Pool yield + ETH gain compounding loop                                | 17_950_000 | positional | structurally-reproducible       | Calm 1-3 bps/cycle; Crisis 50-200 bps/cluster                        |
| F06-03 | F06    | Liquity v2 BOLD redemption sniper (lowest-interest-rate trove)                             | 21_500_000 | atomic     | theoretical (v2 addrs TODO)     | +15-25 bps; +250 bps under 300bp depeg                               |
| F06-04 | F06    | Leveraged BOLD borrow loop against wstETH on Liquity v2                                    | 21_500_000 | positional | theoretical (v2 addrs TODO)     | +$1.5-5k/yr on 10 wstETH @ 5× leverage                               |
| F06-05 | F06    | BOLD system-wide redemption arb via CollateralRegistry + DssFlash + Curve (3-mech)         | 22_500_000 | atomic     | structurally-ready              | +5-15 bps; $800-2,800 per $2M turn; +50-150 bps stress               |
| F06-06 | F06    | LUSD trove → split between Stability Pool and Convex LUSD/3pool (3-mech)                   | 17_900_000 | positional | fully-reproducible              | +5-10% APY net on $100k LUSD over typical 30d window                 |
| F06-07 | F06    | LUSD redemption + GHO + crvUSD triangular stablecoin arb (3-mech)                          | 19_800_000 | atomic     | structurally-reproducible       | +5-25 bps alone; +20-60 bps with triangle; $6-18k per $3M turn       |
| F06-08 | F06    | BOLD SP-mint recycle on the Liquity v2 wstETH branch                                       | 22_500_000 | positional | structurally-complete (gated)   | +0.2-0.4%/yr base; +0.7-1.5%/yr w/ liquidations atop Lido            |
| F07-01 | F07    | PT-sUSDe cash-and-carry, leveraged on Morpho                                              | 20_200_000 | positional | theoretical                     | +25% to +40% / 90d on $1M @ K≈6                                      |
| F07-02 | F07    | PT-weETH leveraged buy on Morpho (ETH-side carry)                                          | 20_650_000 | positional | theoretical                     | +40 to +48 WETH / 180d on 100 WETH @ K≈7-8                           |
| F07-03 | F07    | YT-weETH point speculation                                                                 | 20_650_000 | points     | theoretical                     | Base +30× principal; EV +200%; downside -40%                         |
| F07-04 | F07    | PT/SY redemption arbitrage near maturity                                                   | 20_661_000 | atomic     | theoretical                     | +$900 to +$4,000 / 3d on $1M USDC                                    |
| F07-05 | F07    | PT-rsETH leveraged buy on Morpho (Kelp + Pendle + Morpho, 3-mech)                          | 20_650_000 | positional | theoretical                     | +28 to +34 WETH absolute / 130d on 100 WETH @ K≈5.5 (~$70-85k)       |
| F07-06 | F07    | PT-USD0++ cash-and-carry (Usual + Pendle)                                                  | 20_950_000 | positional | theoretical                     | +$60-85k / 8mo on $1M USDC (≈9-13% APY)                              |
| F07-07 | F07    | PT-sUSDe collateral on Morpho + GHO debt (Pendle + Morpho + GHO, 3-mech)                   | 21_000_000 | positional | theoretical                     | +$150-180k USDC / 60d on $1M @ K≈5.5                                 |
| F07-08 | F07    | PT-sUSDS + Spark + DssFlash bootstrap (Pendle + Morpho/Spark + Maker, 3-mech)              | 21_050_000 | positional | theoretical                     | +$440-510k / 320d on 1M USDS @ K≈8 (91.5% LLTV)                      |
| F07-09 | F07    | YT-pufETH point speculation + PT in Symbiotic vault (3-mech)                               | 20_650_000 | points     | theoretical                     | Cash +1-1.5 WETH; off-chain points +$60-65k; ~25% / 150d total       |
| F08-01 | F08    | sUSDe leveraged supply on Morpho with USDC debt (loop)                                     | 19_800_000 | positional | theoretical                     | +4.1% / 30d on $1M USDe @ K≈4.83 (~$40k net)                         |
| F08-02 | F08    | USDe peg arbitrage via Balancer flash + dual Curve pools (atomic)                          | 19_500_000 | atomic     | theoretical                     | +$500-1,200 / 1M USDT at 15bp edge                                   |
| F08-03 | F08    | PT-sUSDe leveraged buy on Morpho with USDC flashloan                                        | 19_950_000 | positional | theoretical                     | +11.9% / 3.4 months on $100k @ ~5×; annualised ~44%                  |
| F08-04 | F08    | sUSDe stablecoin e-mode loop on Aave v3                                                    | 20_400_000 | positional | theoretical                     | +3.0% / 30d on $1M USDe @ K≈4.91 (~$30k)                             |
| F08-05 | F08    | DssFlash + Aave e-mode + PT-sUSDe sleeve (3-mech)                                          | 20_400_000 | positional | theoretical                     | +4.5% / 30d on 1M DAI @ K≈6 + PT 1× sleeve (~$42k net)               |
| F08-06 | F08    | sUSDe cooldown vs Curve discount arbitrage (2-mech)                                        | 20_400_000 | positional | theoretical                     | +22-30 bps net / 7d yield + entry discount (additive)                |
| F08-07 | F08    | USDe-collateral Morpho loop with off-Morpho sUSDe sleeve (3-mech)                          | 20_400_000 | positional | theoretical                     | Flat standalone; hedge-pair component vs F08-01                      |
| F08-08 | F08    | sUSDe → sUSDS funding rotation when carry inverts (2-mech)                                  | 20_500_000 | positional | theoretical                     | +8.5 bps net / 30d per 100 bps APY gap (defensive)                   |
| F08-09 | F08    | Ethena mint arbitrage + Curve sell + Balancer flash (3-mech)                               | 20_400_000 | atomic     | theoretical                     | +$2-5k / 2M USDC at 15-25 bps premium; $50-200k/yr                   |
| F09-01 | F09    | wstETH/WETH 94.5% LLTV Morpho loop — single-tx bootstrap via Curve stETH pool              | 21_400_000 | atomic     | mechanically-reproducible       | +0.45-0.55 ETH / 30d on 50 ETH (~$1.3-1.65k)                         |
| F09-02 | F09    | sUSDe / DAI 91.5% LLTV Morpho loop — free-flashloan bootstrap                              | 21_400_000 | atomic     | mechanically-reproducible       | +$15-50k / 30d on $400k equity                                       |
| F09-03 | F09    | MetaMorpho idle-liquidity capture — supply to a vault before reallocation                  | 21_400_000 | positional | mechanically-reproducible       | +$4-5.5k / 30d on $1M @ 5-7% APY                                     |
| F09-04 | F09    | Morpho cross-market rate-arb — supply high-rate, borrow low-rate                            | 21_400_000 | atomic     | structurally-verified           | +$500-2,500 / 7-30d on $1M before convergence                        |
| F09-05 | F09    | PT-weETH-26DEC2024 / WETH 86% LLTV Morpho free-flashloan bootstrap (3-mech)                 | 21_300_000 | positional | mechanically-tested             | +4.0-9.6 WETH / 129d on 30 WETH (13-32% absolute)                    |
| F09-06 | F09    | rsETH / WETH 86% LLTV Morpho loop — Morpho free flash + Kelp native deposit (3-mech)        | 21_300_000 | positional | mechanically-tested             | +$500-750 / 30d on 20 ETH equity                                     |
| F09-07 | F09    | PT-USD0++ / USDC 86% LLTV Morpho free-flash leveraged carry (3-mech)                        | 21_000_000 | positional | mechanically-reproducible       | +$8-12k / 245d on $200k (4-6% absolute, 6-9% APY)                    |
| F09-08 | F09    | Cross-MetaMorpho idle-rebalance — pick the best of three USDC vaults                        | 21_400_000 | positional | mechanically-reproducible       | +$2-3.5k / 30d on $2M USDC across 3 vaults                           |
| F09-09 | F09    | Morpho liquidation flash-harvest — capture 5.8% bonus on wstETH/WETH 94.5% (3-mech)         | 21_400_000 | liquidation| mechanically-tested             | +$1,793 net / 10-wstETH liquidation; ~$10k/week dedicated bot        |
| F10-01 | F10    | GHO mint + Balancer GHO/USDC carry                                                          | 20_500_000 | positional | theoretical                     | +1.4-1.6% / 30d on 1M USDC (~$14-16k)                                |
| F10-02 | F10    | Spark sDAI/DAI eMode leveraged loop                                                         | 19_800_000 | positional | theoretical                     | +3,000-3,500 DAI / 30d on 1M DAI                                     |
| F10-03 | F10    | Spark DAI borrow + sDAI / aDAI rate arb (3-mech)                                            | 19_500_000 | positional | theoretical                     | +$1,600-2,000 / 30d on 1M USDC                                       |
| F10-04 | F10    | GHO mint with stkAAVE discount + sDAI/USDS carry                                            | 21_500_000 | positional | theoretical                     | +$750-900 / 30d on 100k USDC + 1k stkAAVE (~5% APR)                  |
| F10-05 | F10    | GHO + Curve + Convex 3-mech boost loop                                                      | 21_000_000 | positional | theoretical                     | +$2,500-3,500 / 14d on 1M USDC at peak Convex emissions              |
| F10-06 | F10    | sDAI + Aave USDC + Spark recursive (3-mech)                                                 | 20_900_000 | positional | theoretical                     | +$7,500-8,200 DAI / 30d on 1M DAI at DSR=8% / borrow=6.5%            |
| F10-07 | F10    | GHO + USDe + Curve + Aave 3-mech                                                            | 20_900_000 | positional | theoretical                     | +$5,000-5,500 / 30d on 1M USDC at peak parameters                    |
| F10-08 | F10    | Aave v3 isolation-mode emissions scanner                                                    | 21_400_000 | positional | theoretical / observational     | Variable per fresh listing; scanner emits no_isolation_candidate     |
| F11-01 | F11    | Compound v3 USDC Comet — leveraged WETH loop                                                | 20_500_000 | positional | theoretical                     | -0.4 to -0.5% flat; +13% / 30d on +3% ETH drift                      |
| F11-02 | F11    | Fluid wstETH/ETH smart-collateral leveraged loop                                            | 21_000_000 | positional | theoretical                     | +1.0-1.4% / 30d on 100 ETH @ K~10                                    |
| F11-03 | F11    | Euler v2 EVC batch — same-asset cross-vault rate arb                                        | 21_200_000 | atomic     | theoretical                     | $40-120/mo per $1M (50-150 bps spread)                               |
| F11-04 | F11    | Cross-MM Comet ↔ Aave USDC supply-rate arbitrage                                            | 20_700_000 | atomic     | theoretical                     | ~$25 / 30d on $200k borrow (scales linearly)                         |
| F11-05 | F11    | Fluid + sUSDe + Pendle PT loop (3-mech)                                                      | 21_400_000 | positional | theoretical                     | +1.0-1.3% / 30d on Fluid NFT @ pinned block                          |
| F11-06 | F11    | Compound v3 + Lido wstETH ETH loop                                                          | 20_800_000 | positional | theoretical                     | +0.4% / 30d at K≈5.6, delta-neutral                                  |
| F11-07 | F11    | Fluid wstETH/USDC + DssFlash atomic bootstrap (3-mech)                                       | 21_000_000 | atomic     | theoretical                     | ~0% / 30d; value is atomicity + primitive composition                |
| F11-08 | F11    | Euler cross-vault USDC rate-sniffer                                                          | 21_300_000 | positional | theoretical                     | +0.05-0.12% / 30d depending on spread persistence                    |
| F12-01 | F12    | Convex Booster LP loop on Curve frxETH/ETH (boosted CRV+CVX+FXS)                            | 19_643_500 | positional | theoretical                     | +$110-130 / 14d / 100 LP gross                                       |
| F12-02 | F12    | vlCVX lock + Votium MultiMerkleStash bribe-claim simulation                                  | 19_643_500 | vote-bribe | theoretical                     | +$800-1,800 / 14d round on 10k CVX                                   |
| F12-03 | F12    | Convex stETH/ETH triple-reward stack (CRV+CVX+LDO)                                           | 19_643_500 | positional | theoretical                     | +$300-400 / 14d / 50 LP                                              |
| F12-04 | F12    | Curve gauge-weight vote snipe via veCRV                                                      | 19_643_500 | vote-bribe | theoretical                     | +$500-3,500 / round on 100k CRV / 4y lock                            |
| F12-05 | F12    | Aura rETH/WETH BPT + HH bribes (3-mech)                                                      | 21_400_000 | vote-bribe | theoretical                     | +$1,000 / 14d / $330k notional (~7.9% APR)                           |
| F12-06 | F12    | Penpie PT-weETH + Pendle vePENDLE bribes (3-mech)                                            | 21_400_000 | vote-bribe | theoretical                     | +$1,800-2,200 / 14d / $160k notional (~26-32% APR)                   |
| F12-07 | F12    | Convex frxETH + FXS compound (3-mech)                                                        | 21_300_000 | positional | theoretical                     | +$140-180 / 14d / 100 LP                                             |
| F12-08 | F12    | Hidden Hand multi-protocol bribe (vlCVX + vlAURA + vePENDLE)                                 | 21_400_000 | vote-bribe | theoretical                     | +$1,500-2,500 / 14d on ~$90k locked (41-72% APR)                     |
| F12-09 | F12    | Convex crvUSD/USDC LP + LLAMMA arb leg (3-mech)                                              | 21_400_000 | positional | theoretical                     | +$300-800 / 14d / $100k notional (8-20% APR)                         |
| F13-01 | F13    | UniV3 wstETH/WETH flashloan + Balancer rate-provider arb                                     | 20_900_000 | atomic     | theoretical                     | -$50 to +$300 / 1000 WETH (stale-window sensitive)                   |
| F13-02 | F13    | Balancer rETH rate-provider lag vs UniV3 rETH/WETH 0.01%                                     | 21_500_000 | atomic     | theoretical (event-driven)      | +$100 to +$2,000 / 500 WETH                                          |
| F13-03 | F13    | Balancer wstETH/WETH ComposableStable LP — double-yield carry                                | 20_900_000 | positional | mechanically-demonstrated       | +1.8-2.3% APR net on 100 WETH                                        |
| F13-04 | F13    | UniV3 wstETH/WETH 0.01% concentrated narrow-range LP                                         | 20_900_000 | positional | mechanically-demonstrated       | 10-25% APR net on 20 ETH (benign markets)                            |
| F13-05 | F13    | UniV3 wstETH/WETH JIT LP backrun                                                              | 20_900_000 | atomic     | mechanically-demonstrated       | +$10 to +$13 net per JIT event                                       |
| F13-06 | F13    | Balancer weETH rate-provider lag + UniV3 + Curve flash 3-leg (3-mech)                         | 21_500_000 | atomic     | mechanically-demonstrated       | +$300-400 at 10 bps spread / 200 WETH notional                       |
| F13-07 | F13    | UniV3 USDC/WETH flashloan + Balancer + Curve peg arb (3-mech)                                | 21_500_000 | atomic     | mechanically-demonstrated       | +$200-700 / 500k USDC notional at 12-25 bps divergence               |
| F13-08 | F13    | Balancer wstETH BPT + Aura stake (3-mech)                                                    | 21_400_000 | positional | mechanically-demonstrated       | +6.0% net APR on 50 WETH                                             |
| F14-01 | F14    | sETH → sUSD atomic vs ETH → USDC Uniswap triangular arbitrage                                | 17_500_000 | atomic     | theoretical                     | notional × \|drift_bps − 50bp\| (live-pair gated)                    |
| F14-02 | F14    | sUSD/3pool depeg arb via Synthetix atomic exchange                                            | 16_818_900 | atomic     | theoretical-historical-replay   | sUSD depeg − 85 bp; profitable at SVB-class events                   |
| F14-03 | F14    | sBTC ↔ sETH ↔ sUSD synth triangular arbitrage                                                 | 17_500_000 | atomic     | theoretical                     | Combined clamp deviation > ~130 bp (oracle-tail)                     |
| F14-04 | F14    | Atomic exchange immediately after Chainlink oracle update                                     | 16_900_000 | atomic     | theoretical                     | Condition-dependent on update event                                  |
| F14-05 | F14    | sBTC/wBTC Balancer flash atomic (3-mech)                                                      | 20_500_000 | atomic     | theoretical                     | Profitable iff \|BTC drift\| > 85 bp; no-op otherwise                |
| F14-06 | F14    | sUSD deep-depeg sBTC backstop (3-mech)                                                        | 16_818_900 | atomic     | theoretical-historical-replay   | depeg_bps − 95 bp; disjoint exit pool vs F14-02                      |
| F14-07 | F14    | Synthetix V3 vault research probe                                                              | 21_000_000 | positional | theoretical / observational     | Reads V3 state — V3 dormant on L1 at late-2024 fork                  |
| F14-08 | F14    | sBTC Chainlink pre-sandwich                                                                    | 21_000_000 | atomic     | theoretical                     | Condition-dependent; no-arb log on median blocks                     |
| F15-01 | F15    | stETH direct EigenLayer deposit vs Renzo ezETH alternative                                    | 19_650_000 | points     | empirically-validated (entry)   | LRT/native +/- $5-10k / 100 stETH split (block-dependent)            |
| F15-02 | F15    | EigenLayer cap-race — be first into the new deposit window                                    | 19_500_021 | points     | mechanically-reproducible       | ~$1.5k / yr / 100 ETH (keeper infra)                                 |
| F15-03 | F15    | EigenLayer 7-day withdrawal-queue exit + secondary market                                     | 19_700_000 | positional | theoretical (gap)               | ~Break-even hold-to-maturity; +$1.5k/cycle w/ hypothetical 2ndary    |
| F15-04 | F15    | Native EigenLayer restake + Symbiotic dual-stack                                              | 20_400_000 | points     | theoretical                     | Bull +$123k/yr; Base +$50-70k; Bear +$10k on 100 wstETH              |
| F15-05 | F15    | EigenLayer operator multi-AVS delegation (3-mech)                                              | 20_500_000 | points     | mechanically-reproducible       | Base +$73k/yr; Bull +$85-100k; Bear +$4.5k on 50 stETH               |
| F15-06 | F15    | EigenPod native validator restake                                                              | 20_600_000 | points     | structural / mechanics-only     | Base +$45k/yr per validator; Bear +$3.8k (CL only)                   |
| F15-07 | F15    | Karak multi-LRT basket vault (3-mech)                                                          | 20_500_000 | points     | mechanically-reproducible       | Bull +$100k+; Base +$60-85k; Bear +$8k on 90 ETH equity              |
| F15-08 | F15    | Symbiotic + Eigen + Pendle YT triple (3-mech)                                                  | 21_000_000 | points     | mechanically-reproducible       | Bull +$500k/yr; Base +$313k/yr; Bear -$74k on 90 wstETH              |
| F16-01 | F16    | LUSD 0%-borrow trove + Aave USDC supply carry                                                  | 20_400_000 | positional | theoretical                     | +2-3% APR on LUSD notional (ex opportunity cost)                     |
| F16-02 | F16    | GHO mint vs crvUSD borrow — cross-CDP rate basis                                               | 20_500_000 | positional | theoretical                     | ~$4.6k / yr on $200k debt (2.3% APR rebate)                          |
| F16-03 | F16    | DSS Flashmint triangular DAI → GHO → crvUSD → DAI                                              | 20_500_000 | atomic     | theoretical                     | +5-15 bps net / $1M typical; +100 bps tail                           |
| F16-04 | F16    | GHO mint → LUSD Stability Pool carry                                                            | 20_500_000 | positional | theoretical                     | +$1.5-2k / 30d on $100k GHO (~18-25% APR LQTY-priced)                |
| F16-05 | F16    | DssFlash + sUSDS + GHO + crvUSD bootstrap (3-mech)                                              | 21_200_000 | atomic     | theoretical                     | +$25-35k / 30d on ~$2M sUSDS residual (~15-20% APR)                  |
| F16-06 | F16    | crvUSD LLAMMA + GHO collateral loop (3-mech)                                                    | 21_000_000 | positional | theoretical                     | +$300-500 / 30d on 100 wstETH; saves ~200 bps vs Aave GHO            |
| F16-07 | F16    | Five-stable cross-CDP basis scanner                                                              | 21_200_000 | positional | theoretical / observational     | Scanner; amortised value ~$10k/yr per 1M basis-trading book          |
| F16-08 | F16    | LUSD trove + crvUSD + Curve/Convex boost (3-mech)                                               | 21_200_000 | positional | theoretical                     | +$10-20k / 30d on 100 ETH (~30-90% APR CRV-priced)                   |
| F17-01 | F17    | USDM rebase carry via Curve crvUSD/USDM pool                                                    | 20_500_000 | positional | mechanically-reproducible       | Strictly-more-units rebase signal (~5% APY)                          |
| F17-02 | F17    | syrupUSDC vs sUSDS carry-stack rotation                                                          | 20_600_000 | positional | mechanically-reproducible       | >1% APY entry spread; positive post-warp share value                 |
| F17-03 | F17    | OETH/ETH Curve depeg + atomic 1:1 redeem arb                                                    | 20_400_000 | atomic     | mechanically-reproducible       | discount > 60 bps gate; profit = (discount − exit_fee) × notional    |
| F17-04 | F17    | OUSD rebase passthrough via Aave supply (with wOUSD wrapper variant)                            | 20_500_000 | positional | theoretical                     | 2× leverage if integration exists; diagnostic otherwise              |
| F17-05 | F17    | sUSDe → sUSDS Aave e-mode rotation (flash atomic, 3-mech)                                        | 20_700_000 | atomic     | mechanically-reproducible       | Spread > threshold; rotation completes in one tx                     |
| F17-06 | F17    | OETH redeem + Aave eMode loop (3-mech)                                                           | 20_400_000 | atomic     | mechanically-reproducible       | One-shot Curve discount + ~3.6× leveraged OETH rebase carry          |
| F17-07 | F17    | syrupUSDC Morpho loop + Pendle PT hedge (3-mech)                                                  | 21_000_000 | positional | theoretical                     | "Long-credit + lend-short + fix-floating" 3-mech stack                |
| F17-08 | F17    | USDM crvUSD LLAMMA amplified carry                                                                | 21_200_000 | positional | theoretical                     | Two-AMM USDM arb venue; complements F17-01 rebase carry              |
| F18-01 | F18    | DssFlash + crvUSD PegKeeper + Curve crvUSD/USDC triangle (3-mech)                                | 21_200_000 | atomic     | mechanically-reproducible       | +$15 to +$2,000 per opp; zero inventory; single-tx atomic            |
| F18-02 | F18    | wstETH → Pendle PT-wstETH → Morpho PT-collateral market (3-tier)                                  | 21_400_000 | positional | mechanically-reproducible       | +$800 to +$2,500 / 30d on 100 wstETH equity                           |
| F18-03 | F18    | Ethena USDe + Curve + Aave USDe-eMode borrow carry (3-mech)                                       | 21_000_000 | positional | mechanically-reproducible       | +$9,000 to +$25,000 / 30d on $1M @ K=5 or full unwind K=14           |
| F18-04 | F18    | Balancer flash + Pendle PT-sUSDe + Morpho USDC/PT cash-and-carry (3-mech)                          | 21_300_000 | atomic     | mechanically-reproducible       | +$500,000 / 5 months net carry on $10M flash (zero equity)            |
| F18-05 | F18    | Same-user triple-restake — EigenLayer + Symbiotic + Karak (3-mech)                                | 21_200_000 | points     | mechanically-reproducible       | +$500-4,000 points-equivalent / 30d on $450k (high uncertainty)      |
| F18-06 | F18    | Synthetix sUSD atomic exit + Curve sUSD/3pool + Aave aDAI carry (3-mech)                          | 21_000_000 | atomic     | mechanically-reproducible       | +$3,500 to +$5,500 / 30d on $2M (small arb + aDAI yield)             |

---

## Section B — Family roll-up

### F01 — LST looping (8 strategies)
**Description:** Leverage looping of stETH / wstETH / rETH / cbETH / sfrxETH via Aave / Morpho / Compound / Fluid / Spark / Fraxlend.
**Key idea:** Extract the spread between LST staking yield + supply APR and the variable WETH borrow rate, amplified by 5-14× via correlated-asset eMode collateral factors. Wave 4 broadened to a second-borrow-asset triangle (rETH → Spark DAI → sDAI) and to non-Aave money markets (Comet, Fluid, Fraxlend) plus a Pendle PT hedge.
**Strategies:** F01-01, F01-02, F01-03, F01-04, F01-05, F01-06, F01-07, F01-08

### F02 — LRT looping & restake (8 strategies)
**Description:** EtherFi / Renzo / Kelp / Puffer leveraged restaking and points farming.
**Key idea:** Same loop mechanics as F01 but pointed at LRTs, where the *real* payoff is the multi-protocol point stack (EtherFi loyalty + EigenLayer + LRT-native + EIGEN/REZ/PUFFER/SYMB airdrops). Wave 4 added rsETH × Kelp × Karak × Pendle YT three-stream stacks (F02-05), pufETH × Symbiotic × Aave triple (F02-06), weETH PT/YT split via Morpho flash (F02-07), and weETH on Fluid smart-collateral (F02-08) — the only F02 strategy with positive cash leg.
**Strategies:** F02-01..F02-08

### F03 — LST/LRT basis & peg (9 strategies)
**Description:** Curve / Balancer peg arbitrage between LSTs/LRTs and ETH, withdrawal queues.
**Key idea:** Atomic flashloan-driven trades that exploit (a) AMM depegs vs the LST's redeem path, and (b) lag between a Balancer rate-provider cache and the live exchange-rate function. Wave 4 added a wrap-path triangular (F03-05), a multi-LRT cross-pool triangle pinned to ezETH crash (F03-06), cbETH-rate-update arb (F03-07), frxETH rate-provider mismatch (F03-08) and a Pectra-fork weETH depeg (F03-09).
**Strategies:** F03-01..F03-09

### F04 — Maker DSR / sDAI / sUSDS (8 strategies)
**Description:** DSR-anchored yield, PSM hops, sDAI / sUSDS leveraged via flash mint.
**Key idea:** Maker's free flashmint (DssFlash) + zero-fee PSM is the only fully-fee-free leg in DeFi; the family stacks it with Spark borrows and Aave supply to capture rate divergences. Wave 4 added a DaiUsds slippage probe (F04-05) for cost-basis grounding, a Morpho 3-mech recursive (F04-06), a DssFlash-LUSD redemption cross-CDP arb (F04-07), and a USDC-borrow rotation variant (F04-08).
**Strategies:** F04-01..F04-08

### F05 — crvUSD LLAMMA (8 strategies)
**Description:** Soft-liquidation arbitrage and leveraged crvUSD borrows against LSTs.
**Key idea:** LLAMMA's `price_oracle()` EMA lags spot on fast moves — searchers buy collateral cheap from the in-band liquidating range, and (separately) flashmint DAI to arb crvUSD's peg via Curve. Wave 4 added an sfrxETH variant (F05-05), a tBTC market harvest (F05-06), a crvUSD → sUSDe Morpho recursive (F05-07) and a crvUSD/USDC Convex LP composed with a LLAMMA arb leg (F05-08).
**Strategies:** F05-01..F05-08

### F06 — Liquity v1 / v2 (LUSD / BOLD) (8 strategies)
**Description:** Stability pool yield, redemption arbitrage, BOLD interest-rate dynamics.
**Key idea:** Liquity redemptions are atomic, 1:1 against the lowest-CR (v1) or lowest-rate (v2) trove — combined with a Maker flashmint that funds the redemption, this is one of the rare zero-capital alpha sources during peg stress. Wave 4 added a CollateralRegistry-aware system-wide v2 redemption (F06-05), an SP-and-Convex split (F06-06), a LUSD-GHO-crvUSD stablecoin triangle (F06-07), and a v2 wstETH-branch SP-mint recycle (F06-08).
**Strategies:** F06-01..F06-08

### F07 — Pendle PT / YT (9 strategies)
**Description:** PT leveraged buy, YT yield speculation, SY composition with LST/LRT/stables.
**Key idea:** PT is sold at a discount to underlying; looping it on Morpho captures the pull-to-par. YT decouples the points stream from the principal — the highest-asymmetry leg in this whole research corpus. Wave 4 added PT-rsETH on Morpho (F07-05), PT-USD0++ Usual carry (F07-06), PT-sUSDe with GHO debt (F07-07), PT-sUSDS + Spark + DssFlash bootstrap (F07-08), and YT-pufETH + PT in Symbiotic (F07-09).
**Strategies:** F07-01..F07-09

### F08 — Ethena USDe / sUSDe (9 strategies)
**Description:** sUSDe carry, Pendle PT-sUSDe, looped sUSDe on Morpho / Aave.
**Key idea:** sUSDe APY is internet-bond-style funded by perp basis; looping it 4-5× on Morpho/Aave with USDC debt is the cleanest stable-stable rate-spread carry in the corpus. Wave 4 added DssFlash + Aave eMode + PT sleeve (F08-05), sUSDe cooldown vs Curve discount (F08-06), USDe-collateral Morpho with sUSDe sleeve (F08-07), sUSDe → sUSDS rotation (F08-08), and Ethena mint + Curve + Balancer arb (F08-09).
**Strategies:** F08-01..F08-09

### F09 — Morpho Blue isolated markets (9 strategies)
**Description:** Custom market loops, flashloan-bootstrap, idle-liquidity capture.
**Key idea:** Morpho's free flashloan (callback model, no premium) enables one-tx loop bootstrap; the per-market isolation lets curators set 94.5% LLTV on assets Aave can't touch. F09 is the *strongest* mechanically-reproducible family in the corpus — every strategy opens its position on-fork. Wave 4 added PT-weETH (F09-05), rsETH × Kelp loop (F09-06), PT-USD0++ (F09-07), cross-MetaMorpho rebalance (F09-08), and Morpho liquidation flash-harvest (F09-09).
**Strategies:** F09-01..F09-09

### F10 — Aave v3 / Spark / GHO (8 strategies)
**Description:** E-mode loops, GHO mint-and-deploy, isolation-mode farming.
**Key idea:** GHO is variable-rate-minted at a discount for stkAAVE holders; combined with Aave eMode and Spark's DSR-pegged DAI, this is the on-chain stable-rate basis surface. Wave 4 added a GHO + Curve + Convex 3-mech boost (F10-05), an sDAI + Aave + Spark recursive (F10-06), a GHO + USDe + Curve + Aave 3-mech (F10-07), and an isolation-mode emissions scanner (F10-08).
**Strategies:** F10-01..F10-08

### F11 — Compound v3 + Fluid + Euler (8 strategies)
**Description:** Cross-money-market rate arbitrage and isolated-vault composability.
**Key idea:** USDC supply rates diverge by 50-170 bps across Comet / Aave / Fluid / Euler vaults; the Euler v2 EVC enables a same-tx multi-vault batch that no other MM can match. Wave 4 added a Fluid + sUSDe + Pendle PT loop (F11-05), a Comet ETH + Lido wstETH loop (F11-06), a Fluid + DssFlash atomic bootstrap (F11-07), and an Euler cross-vault USDC sniffer (F11-08).
**Strategies:** F11-01..F11-08

### F12 — Curve + Convex + bribes (9 strategies)
**Description:** vlCVX vote-directed bribes, Votium / Hidden-Hand claim loops, gauge ecosystem.
**Key idea:** vlCVX abstracts the veCRV vote market — bribe income on a 14-day round basis is the highest-IRR purely-positional return in the corpus, gated only on willing-to-lock duration. Wave 4 expanded into Aura (F12-05), Penpie / vePENDLE (F12-06), Convex frxETH+FXS (F12-07), a triple-protocol HH bribe (F12-08), and a Convex crvUSD/USDC LP composed with a LLAMMA arb leg (F12-09).
**Strategies:** F12-01..F12-09

### F13 — Balancer / Uniswap v3 LP (8 strategies)
**Description:** Concentrated liquidity + boosted-pool stacking with LST primary tokens.
**Key idea:** Balancer's rate-provider cache (24h heartbeat) goes stale relative to live LST exchange rates — UniV3 flash + 2-leg swap captures the gap atomically. Wave 4 added a UniV3 JIT-LP backrun (F13-05), a 3-leg Balancer/UniV3/Curve weETH arb (F13-06), a UniV3 + Balancer + Curve peg arb (F13-07), and a Balancer BPT → Aura stake (F13-08). Wave 4 also pushed every F13 strategy to `mechanically-demonstrated` status.
**Strategies:** F13-01..F13-08

### F14 — Synthetix atomic + sUSD (8 strategies)
**Description:** sUSD / sETH atomic-swap arbitrage and synth-as-collateral composites.
**Key idea:** Synthetix's atomic-exchange "fair value" exit ramp clamps to the worse-of-two oracles; when one oracle is stale, that clamp is the arbitrageur's bid. Wave 4 added a sBTC/wBTC Balancer flash arb (F14-05), a deep sUSD depeg sBTC backstop (F14-06), a Synthetix V3 research probe (F14-07) and a sBTC Chainlink pre-sandwich (F14-08).
**Strategies:** F14-01..F14-08

### F15 — EigenLayer native restake (8 strategies)
**Description:** Direct EigenLayer strategy deposits, AVS rewards, LRT-vs-native comparisons.
**Key idea:** Native restake captures the same EIGEN-points stream as the LRTs but without the wrapper-token depeg risk; cap-races and 7-day withdrawal queues are exploitable secondary markets. Wave 4 added operator-AVS multi-delegation (F15-05), EigenPod native validator (F15-06), Karak multi-LRT basket (F15-07), and a Symbiotic+Eigen+Pendle triple (F15-08) — the highest expected-value strategy in the F15 family.
**Strategies:** F15-01..F15-08

### F16 — Cross-CDP basis (8 strategies)
**Description:** Multi-CDP loops mixing GHO / crvUSD / DAI / LUSD as base debt.
**Key idea:** Every CDP system prices its own borrow rate independently; the basis between GHO, crvUSD, DAI and LUSD borrow rates is sometimes 100+ bps and tradable via DssFlash triangulation. Wave 4 added a DssFlash + sUSDS + GHO + crvUSD atomic bootstrap (F16-05), a crvUSD LLAMMA + GHO loop (F16-06), a five-stable basis scanner (F16-07), and a LUSD trove + Curve/Convex boost variant (F16-08).
**Strategies:** F16-01..F16-08

### F17 — Yield-bearing stable carry (8 strategies)
**Description:** USDM / USDY / OUSD / syrupUSDC carry stacks vs sDAI / sUSDS baseline.
**Key idea:** Each yield-bearing stable expresses its yield differently (rebase, share-price, wrapper) and trades at different Curve discounts — pure-stable rotations capture both the APY differential and the entry-discount. Wave 4 added a sUSDe → sUSDS Aave eMode rotation (F17-05), an OETH redeem + Aave eMode loop (F17-06), a syrupUSDC Morpho + Pendle hedge (F17-07), and a USDM amplified-carry on LLAMMA (F17-08).
**Strategies:** F17-01..F17-08

### F18 — Tri-protocol mechanism stacks (6 strategies) — NEW IN WAVE 4
**Description:** Strategies that explicitly compose ≥3 distinct DeFi protocol mechanisms in a single trade or position. F18 is the corpus's deliberate stress-test for true tri-protocol composability: every member's "Why it composes" section enumerates three mechanisms and explicitly argues that no 2-mechanism subset achieves the same outcome.
**Key idea:** The three-mechanism constraint is the *binding* design pattern — pick three primitives that each contribute a non-substitutable economic property (e.g. liquidity, leverage, fixed-rate decoupling, point-stream isolation, atomic-exit clamping). F18 is intentionally cross-cutting: it borrows ideas from F04, F07, F08, F10, F14, F15 and re-targets them around composability rather than yield maximisation.
**Strategies:** F18-01..F18-06

---

## Section C — Filter views (top-N)

**Sorting heuristic (footnote).** Wave-2/Wave-4 PnL estimates are
expressed in many units (USD, ETH, % APR, % over horizon, point-airdrop
value). To produce a single comparable number we use the following
normalisation, computed manually per row:

1. If the estimate is given as a USD range over a horizon, take the
   range midpoint and rescale to a 30-day window. Example:
   `+$15-50k / 30d` → midpoint $32.5k.
2. If the estimate is given as a percentage over a horizon on a stated
   notional, multiply midpoint% × notional and rescale to 30 days.
   Example: `+4.1% / 30d on $1M` → $41k.
3. Points-based strategies use the **base case (one airdrop realised)**
   number, not the bull tail.
4. Strategies whose PnL is per-opportunity (atomic depeg arbs) use
   per-opportunity midpoint × an assumed 1 opportunity / 30 days unless
   the README states a different opportunity frequency.
5. ETH-denominated estimates are converted at $2,500 / ETH (the price
   floor used throughout the corpus READMEs).
6. F18-04's $500k / 5 months entry is rescaled to 30 days → ~$100k
   normalised (with the explicit caveat that this is a fixed-at-maturity
   PT pull-to-par, not a constant-rate carry).

These heuristics are **lossy** — the ranking is for navigation, not for
deciding what to deploy. The real PnL is the README plus the
fork-replay.

### Top 10 by expected gross 30-day PnL (USD-normalised)

| Rank | ID     | Title                                                          | 30d-norm USD       | Type       |
| ---- | ------ | -------------------------------------------------------------- | ------------------ | ---------- |
| 1    | F18-04 | Balancer flash + PT-sUSDe + Morpho cash-and-carry              | ~$100k             | atomic     |
| 2    | F07-07 | PT-sUSDe collateral on Morpho + GHO debt                       | ~$82k (60d→30d)    | positional |
| 3    | F07-08 | PT-sUSDS + Spark + DssFlash bootstrap                          | ~$45k (320d→30d)   | positional |
| 4    | F18-03 | Ethena USDe + Curve + Aave USDe-eMode carry                    | ~$17k              | positional |
| 5    | F08-01 | sUSDe leveraged supply on Morpho with USDC debt                | ~$40k              | positional |
| 6    | F08-05 | DssFlash + Aave e-mode + PT-sUSDe sleeve                       | ~$42k              | positional |
| 7    | F07-01 | PT-sUSDe cash-and-carry on Morpho                              | ~$36k (90d→30d)    | positional |
| 8    | F09-02 | sUSDe / DAI 91.5% LLTV Morpho loop                             | ~$32.5k            | atomic     |
| 9    | F08-04 | sUSDe stablecoin e-mode loop on Aave v3                        | ~$30k              | positional |
| 10   | F10-06 | sDAI + Aave + Spark recursive (3-mech)                         | ~$7.85k            | positional |

(Rows that are points-dominated have been placed using the README's
**base / median airdrop realised** estimate. Bull-tail outcomes for
F02-02 / F02-03 / F02-06 / F02-07 / F07-03 / F15-04 / F15-08 / F18-05
would all dominate this list, but they depend on TGE pricing not knowable
on-chain at fork time.)

### Top 10 atomic strategies (single-tx, capital-free / flashloan-bootstrapped)

| Rank | ID     | Title                                                          | Best estimate         |
| ---- | ------ | -------------------------------------------------------------- | --------------------- |
| 1    | F18-04 | Balancer flash + PT-sUSDe + Morpho cash-and-carry              | +$500k / 5mo / $10M flash |
| 2    | F03-06 | Multi-LRT triangular depeg (ezETH × weETH × rsETH)             | +$30-85k / 200 WETH at depeg peak |
| 3    | F03-02 | ezETH/WETH Balancer depeg arb (Renzo April 2024)               | +$10-90k / event      |
| 4    | F05-04 | crvUSD peg arbitrage via Maker DSS-Flash + Curve               | +$1-60k / event       |
| 5    | F03-09 | weETH Pectra-fork depeg (4-mech)                               | +$20-60k / 800 WETH   |
| 6    | F04-07 | DssFlash + LUSD-Curve + Liquity redemption                     | ~$45k on 2M DAI flash |
| 7    | F08-09 | Ethena mint arb + Curve + Balancer flash                       | +$2-5k / 2M USDC; $50-200k/yr |
| 8    | F16-05 | DssFlash + sUSDS + GHO + crvUSD bootstrap                      | +$25-35k / 30d        |
| 9    | F06-01 | LUSD redemption arb (DSS flashmint)                            | +$5-15k / $10M turn   |
| 10   | F18-01 | DssFlash + crvUSD PegKeeper + Curve triangle                   | +$15-2,000 / opp, zero inventory |

### Top 10 positional strategies (carry-style)

| Rank | ID     | Title                                                          | 30d-norm USD          |
| ---- | ------ | -------------------------------------------------------------- | --------------------- |
| 1    | F07-07 | PT-sUSDe + Morpho + GHO (3-mech)                               | ~$82k / $1M, 60d→30d  |
| 2    | F07-08 | PT-sUSDS + Spark + DssFlash bootstrap (3-mech)                 | ~$45k / 320d annualised |
| 3    | F08-05 | DssFlash + Aave eMode + PT-sUSDe sleeve (3-mech)               | ~$42k / $1M, 30d      |
| 4    | F08-01 | sUSDe Morpho USDC loop                                         | ~$40k / $1M, 30d      |
| 5    | F07-01 | PT-sUSDe cash-and-carry on Morpho                              | ~$36k / $1M, 90d→30d  |
| 6    | F08-04 | sUSDe stablecoin eMode loop on Aave v3                         | ~$30k / $1M, 30d      |
| 7    | F18-03 | Ethena + Curve + Aave USDe-eMode carry (3-mech)                | ~$17k / $1M, 30d      |
| 8    | F10-01 | GHO mint + Balancer GHO/USDC carry                             | ~$15k / 1M USDC, 30d  |
| 9    | F16-08 | LUSD trove + crvUSD + Curve/Convex boost (3-mech)              | ~$15k / 100 ETH, 30d  |
| 10   | F11-02 | Fluid wstETH/ETH smart-collateral loop                         | ~$7.5k / 100 ETH, 30d |

### Top 10 points-based strategies (base-case airdrop realised)

| Rank | ID     | Title                                                          | Base case             |
| ---- | ------ | -------------------------------------------------------------- | --------------------- |
| 1    | F15-08 | Symbiotic + Eigen + Pendle YT triple                           | +$313k / yr base on 90 wstETH |
| 2    | F02-06 | pufETH + Symbiotic + Aave eMode triple                         | +$200-300k / yr       |
| 3    | F02-03 | pufETH Karak / Symbiotic re-deposit                            | +$250-500k full stack |
| 4    | F02-07 | weETH PT/YT split + Morpho flash                               | +$500-700k / 120d base |
| 5    | F02-02 | ezETH points farming via Pendle YT                             | +$140-400k / 120d base |
| 6    | F15-04 | Native EigenLayer + Symbiotic dual-stack                       | +$50-70k / yr base    |
| 7    | F15-07 | Karak multi-LRT basket (3-mech)                                | +$60-85k / yr base    |
| 8    | F15-05 | EigenLayer operator multi-AVS delegation                       | +$73k / yr base       |
| 9    | F02-04 | weETH Aave V3 eMode + restake                                  | +$100k / yr base      |
| 10   | F02-08 | weETH Fluid smart-collateral loop                              | +$50-80k / yr base    |

### Top 10 NEW 3-mechanism strategies (Wave 4 deepening + F18)

Strategies whose README "Why it composes" enumerates **3+ distinct
DeFi protocol mechanisms**, ranked by 30d-normalised expected PnL:

| Rank | ID     | Title                                                          | Family | Mechanisms                          |
| ---- | ------ | -------------------------------------------------------------- | ------ | ----------------------------------- |
| 1    | F18-04 | Balancer flash + Pendle PT-sUSDe + Morpho USDC/PT              | F18    | Balancer + Pendle + Morpho          |
| 2    | F07-07 | PT-sUSDe Morpho + GHO debt                                     | F07    | Pendle + Morpho + GHO               |
| 3    | F07-08 | PT-sUSDS + Spark + DssFlash bootstrap                          | F07    | Pendle + Spark + Maker              |
| 4    | F08-05 | DssFlash + Aave eMode + PT-sUSDe sleeve                        | F08    | Maker + Aave + Pendle               |
| 5    | F18-03 | Ethena + Curve + Aave USDe-eMode                               | F18    | Ethena + Curve + Aave               |
| 6    | F16-05 | DssFlash + sUSDS + GHO + crvUSD bootstrap                      | F16    | Maker + Sky + Aave/GHO + Curve      |
| 7    | F16-08 | LUSD trove + crvUSD + Curve/Convex boost                       | F16    | Liquity + crvUSD + Convex           |
| 8    | F10-06 | sDAI + Aave USDC + Spark recursive                             | F10    | Sky/sDAI + Aave + Spark             |
| 9    | F07-09 | YT-pufETH + PT in Symbiotic vault                              | F07    | Puffer + Pendle + Symbiotic         |
| 10   | F18-06 | Synthetix sUSD exit + Curve + Aave aDAI carry                  | F18    | Synthetix + Curve + Aave            |

(For a full list of all 3-mechanism strategies across families see
REPORT.md §4. The full set is 65 strategies out of 147, with F18 being
6/6 by design and F08 / F16 the densest among the deepened families.)

---

*This index is a navigation aid. The authoritative source for each
strategy is the per-strategy README and PoC. See REPORT.md for
methodology, family-by-family findings, cross-family observations and
the verification checklist.*
