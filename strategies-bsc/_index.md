# BSC Strategies Index (Wave 4 aggregate)

This index is generated from `strategies-bsc/B*/README.md` files. It is the sortable master list of every PoC produced by the BSC research waves.

- **127** strategies across **15** families (B01..B15).
- Wave 1 = BSC repo skeleton (`src/constants/BSC.sol`, `src/interfaces/bsc/`, `BSCStrategyBase`, `BSC_STRATEGY_IDS.md`). Wave 2 = 15 family agents producing 62 baseline PoCs (slots `BXX-01..04`, with some families closing at 04 and a few at 03). Wave 3 = this aggregator. Wave 4 = 15 family-deepening agents adding 65 PoCs in slots `BXX-05..10`.
- The BSC subtree is intentionally **disjoint** from the Ethereum subtree (`strategies/Fxx-*`); the mainnet REPORT and index remain untouched.
- Status taxonomy: `theoretical` (built from docs, not fork-replayed because no BSC archive RPC was configured), `offline-draft` (compiles but pinned to a synthetic / TODO-verify block — the B03 / B10 / B15 families use this label).
- BSC.sol was patched mid-Wave-2 to fix EIP-55 checksums on Astherus / Wombat / Avalon addresses. Several PoCs still carry inline `LOCAL_*` placeholders for addresses that are not yet in `BSC.sol` (see Section A and the Verification TODO in `REPORT_BSC.md`).

---

## Section A — Strategy table

Sorted by family then by NN. `Block` is the fork-pin read from each README's `## Block pinned` section, falling back to the `FORK_BLOCK` constant in the PoC if no README pin exists. `Type` is one of:
`atomic` (single-tx, flashloan-bootstrapped depeg / rate-cache / cross-DEX arb), `positional` (multi-block carry, leveraged loop, LP, CDP recursive mint), `points` (Pendle YT + airdrop speculation), `vote-bribe` (veTHE / veCAKE / Hidden Hand BSC governance economics), `liquidation` (Venus / Avalon / Lista keeper).
`Expected PnL` is paraphrased from the README's `## Result` / `## Status & PnL` block; the full text lives in the per-strategy README.

| ID     | Family | Title | Block | Type | Status | Expected PnL (summary) |
| ------ | ------ | ----- | ----- | ---- | ------ | ---------------------- |
| B01-01 | B01    | slisBNB → Venus core pool → borrow BNB → Lista re-stake loop | 40_000_000 | positional | theoretical | +0.4–0.7 BNB per 100 BNB |
| B01-02 | B01    | Stader BNBx → Venus isolated pool → borrow BNB → BNBx re-stake loop | 40_500_000 | positional | theoretical | +0.4–0.7 BNB per |
| B01-03 | B01    | ankrBNB → Lista Lending → borrow BNB → Ankr re-stake loop | 41_000_000 | positional | theoretical | +0.3–0.6 BNB per 100 BNB over 30 days, with |
| B01-04 | B01    | 50/50 slisBNB + BNBx basket on Venus → borrow BNB → split re-stake | 40_000_000 | positional | theoretical | +0.4–0.6 |
| B01-05 | B01    | stkBNB (pSTAKE) → Venus → borrow BNB → pSTAKE re-stake loop | 42_500_000 | positional | theoretical | +0.4–0.7 BNB per |
| B01-06 | B01    | slisBNB Venus loop + Pendle PT-slisBNB rate hedge (3-mechanism) | 42_000_000 | positional | theoretical | +0.45–0.65 BNB / 100 BNB / 30 days |
| B01-07 | B01    | BNBx → Lista Lending → borrow WBNB → Wombat WBNB/BNBx recycle (3-mech) | 41_500_000 | positional | theoretical | +0.5–0.6 BNB per 100 BNB / 30 days |
| B01-08 | B01    | WBETH (bridged Beacon ETH) → Venus → borrow peg-ETH → re-mint loop | 42_000_000 | positional | theoretical | +0.13–0.18 ETH per 30 ETH / 30 |
| B02-01 | B02    | slisBNB / WBNB PancakeSwap v3 single-pool flash arb | 45_000_000 | atomic | theoretical | +$300 to +$2,000 per 1000 WBNB at typical dislocations. |
| B02-02 | B02    | BNBx / WBNB Thena ve(3,3) vs Stader internal rate arb | 45_000_000 | atomic | theoretical | +$400 to +$3,000 per 1000 WBNB depending on Thena epoch. |
| B02-03 | B02    | ankrBNB `ratio()` vs PCS v3 spot single-pool flash arb | 45_000_000 | atomic | theoretical | +$200 to +$3,000 per 1000 WBNB depending on inter-tier |
| B02-04 | B02    | WBETH (BSC) `exchangeRate()` vs PCS v3 ETH/WBETH spot lag | 45_000_000 | atomic | theoretical | +$400 to +$2,500 per 150 WETH at typical mid-day |
| B02-05 | B02    | slisBNB / WBNB PancakeSwap StableSwap dynamic-fee balance-restoration arb | 45_100_000 | atomic | theoretical | +$300 – $1,000 per 1,000 WBNB at typical |
| B02-06 | B02    | Triangular stkBNB ↔ WBNB ↔ slisBNB cross-LST arb on Wombat + PCS v3 (3-mechanism) | 45_200_000 | atomic | theoretical | +$200 – $1,800 per 500 WBNB ticket (40 bp band). |
| B02-07 | B02    | slisBNB PCS v3 flash + Thena solidly-stable swap + Lista internal rate (3-mechanism) | 45_300_000 | atomic | theoretical | +$200 – $1,800 per 800 WBNB ticket (10-50 bp band). |
| B02-08 | B02    | 3-venue atomic MEV-style cycle on slisBNB (PCS v3 + Thena + Wombat, 3-mechanism) | 45_400_000 | atomic | theoretical | +$280 – $3,200 per 600 WBNB ticket (8-90 bp band). |
| B03-01 | B03    | lisUSD depeg atomic arb via PCS v3 flash + Lista payback | 42_500_000 | atomic | offline-draft | modelled at `+25 bp net` of notional (50 bp gross discount |
| B03-02 | B03    | slisBNB · Lista CDP recursive leverage loop | 42_500_000 | positional | offline-draft | with `slisBNB_apr = 3.2%`, `lisUSD_borrow = 2.0%`, |
| B03-03 | B03    | lisUSD ↔ USDe cross-CDP carry basis | 42_500_000 | positional | offline-draft | at 12% sUSDe APY, 2.5% Lista borrow, 60 days hold, on a |
| B03-04 | B03    | lisUSD cross-venue StableSwap arb (PCS v3 ↔ Wombat) | 42_500_000 | atomic | offline-draft | at 10 bp basis on a $1m notional, the strategy nets |
| B03-05 | B03    | Lista clip-auction keeper (lisUSD -> discounted slisBNB) | 42_500_000 | liquidation | offline-draft | on a $500k clip take, capturing a 300 bp discount and |
| B03-06 | B03    | Dual-collateral Lista (ETH + slisBNB) → lisUSD → PCS v3 LP | 42_500_000 | positional | offline-draft | see README |
| B03-07 | B03    | lisUSD → Pendle PT lock + Venus secondary borrow | 42_500_000 | positional | offline-draft | PnL model (90-day hold, $60k slisBNB collateral, $45k lisUSD |
| B03-08 | B03    | slisBNB → Lista mint lisUSD → Venus borrow BNB → recursive restake | 42_500_000 | positional | offline-draft | see README |
| B04-01 | B04    | PT-sUSDe BSC cash-and-carry (fixed-yield to maturity) | 42_000_000 | positional | theoretical | +50 000 to +70 000 USDC per 1 M held to a 6-month maturity. |
| B04-02 | B04    | PT-slisBNB BSC cash-and-carry (BNB staking yield locked) | 42_000_000 | positional | theoretical | +2.5 to +3.0 BNB per 100 BNB held to 6-month maturity. |
| B04-03 | B04    | YT-slisBNB points speculation (mint PY, sell PT, keep YT) | 42_000_000 | points | theoretical | ~96 BNB of YT exposure for ~7.8 BNB equity, ~12× point |
| B04-04 | B04    | PT-sUSDe BSC near-maturity redemption arb (4-day carry) | 47_000_000 | atomic | theoretical | +250 to +750 USDC per 500 k notional over 4 days, i.e. |
| B04-05 | B04    | PT-asBNB BSC + Venus collateral + USDT borrow (3-mechanism) | 44_500_000 | positional | theoretical | +$2,400-$3,600 per 200 BNB held 3 months. |
| B04-06 | B04    | PT-USDe BSC + Lista CDP recursive (3-mechanism) | 42_000_000 | positional | theoretical | see README |
| B04-07 | B04    | YT-asBNB Astherus airdrop / points speculation | 44_500_000 | points | theoretical | - Astherus airdrop expected: rumored Q3-Q4 2025, snapshot likely tied to |
| B04-08 | B04    | PT-slisBNB Pendle + Venus collateral + Lista lisUSD borrow (3-mech) | 44_000_000 | positional | theoretical | +$3-5k per 150 BNB held to maturity, scaling linearly. |
| B04-09 | B04    | Pendle BSC market PT vs Wombat / PCS spot arb (3-mechanism) | 44_000_000 | atomic | theoretical | - Net expected per round trip: 30-70 bps × 25 BNB = +0.075 to +0.175 BNB |
| B05-01 | B05    | sUSDe → Venus collateral → borrow USDT → buy USDe → stake → recursive loop | 42_500_000 | positional | theoretical | +0.8 – 1.5 % over 30 |
| B05-02 | B05    | USDe peg arbitrage — PCS v3 flash → Wombat StableSwap → repay | 42_800_000 | atomic | theoretical | +0.15 |
| B05-03 | B05    | sUSDe → Lista lending → borrow lisUSD → swap USDe → re-stake loop | 42_500_000 | positional | theoretical | +1.4 – 1.9 % over 30 days on |
| B05-04 | B05    | Funding-flip rotation — sUSDe ↔ slisBNB (Ethena vs Lista BNB stake) | 44_000_000 | positional | theoretical | roughly breakeven at 30 days, +0.15 – |
| B05-05 | B05    | PT-sUSDe (Pendle) + Lista lending + USDe — 3-mechanism carry | 42_900_000 | positional | theoretical | +2,500–3,000 USD on $100k over 60 days (~17% APY |
| B05-06 | B05    | USDe Venus + PCS v3 flash atomic 3-mechanism position-builder | 42_700_000 | atomic | theoretical | +$4,400 free equity on zero |
| B05-07 | B05    | sUSDe + Astherus asBNB + PCS LP — 3-mechanism triangular yield | 43_100_000 | atomic | theoretical | +$630 / |
| B05-08 | B05    | Ethena Reserve-Fund-related basis anomaly (sUSDe APY mean-reversion) | 43_300_000 | positional | theoretical | +$149 on $100k |
| B06-01 | B06    | Venus Core Pool vs LST isolated pool — USDT supply/borrow rate arb | 42_500_000 | atomic | theoretical | +$1,400–$2,500 per $100k |
| B06-02 | B06    | Venus Core Pool VAI mint + Pancake StableSwap VAI/USDT carry | 42_500_000 | positional | theoretical | +$10k–$12k per 1M USDC |
| B06-03 | B06    | Venus LST isolated pool — slisBNB high-LTV leveraged loop | 42_500_000 | positional | theoretical | +0.60 BNB per 100 BNB |
| B06-04 | B06    | VAI depeg — atomic PCS v3 flash + Venus repayVAI arb | 42_500_000 | atomic | theoretical | Status: theoretical, offline. Expected net per atomic call at the |
| B06-05 | B06    | Venus liquidation keeper — atomic flash + liquidate + DEX | 42_500_000 | liquidation | theoretical | Status: theoretical, offline. Expected net ~$24k per successful |
| B06-06 | B06    | Cross isolated-pool collateral migration (Venus Core → LST pool) | 42_500_000 | positional | theoretical | Status: theoretical, offline. Expected net ~$570 over 60 days |
| B06-07 | B06    | VAI mint + PCS StableSwap LP + Lista lisUSD CDP — stable trifecta | 42_500_000 | positional | theoretical | Status: theoretical, offline. Expected net ~$16k per $1M per 60 |
| B06-08 | B06    | Venus LST isolated pool — WBETH/WETH eMode-style loop | 42_500_000 | positional | theoretical | Status: theoretical, offline. Expected net ~$4.2k per $300k WBETH |
| B07-01 | B07    | PCS v3 USDT/WBNB 0.01% flash → Thena USDT/WBNB volatile pair arb | 42_000_000 | atomic | theoretical | +$30–80 per |
| B07-02 | B07    | PCS v3 BTCB/USDT 0.05% flash → Thena BTCB/USDT volatile arb | 42_000_000 | atomic | theoretical | +$150–500 per fire at |
| B07-03 | B07    | PCS v3 CAKE/WBNB 0.25% flash → Thena CAKE/BNB vAMM arb | 42_000_000 | atomic | theoretical | +$500–3_000 per fire at 120–200 |
| B07-04 | B07    | PCS v3 USDC/USDT 0.01% flash → Wombat USDC→USDT → PCS StableSwap USDT→USDC → repay | 42_000_000 | atomic | theoretical | +$300–2_000 per fire at 10–30 |
| B07-05 | B07    | PCS v3 ETH/WBNB 0.05% flash → Thena ETH/BNB volatile arb | 42_000_000 | atomic | theoretical | +$200–1000 per fire at 40–80 bp |
| B07-06 | B07    | PCS v3 cross-fee-tier USDT/WBNB micro-spread arb (0.01% vs 0.05% vs 0.25%) | 42_000_000 | atomic | theoretical | +$15–80 per fire on the |
| B07-07 | B07    | PCS v3 flash → Pendle PT-sUSDe swap → Venus collateral & borrow | 42_000_000 | atomic | theoretical | see README |
| B07-08 | B07    | PCS v3 USDC flash → Lista lisUSD mint → PCS StableSwap exit | 42_000_000 | atomic | theoretical | +$300–800 per fire at |
| B07-09 | B07    | PCS v3 USDC flash + 4-DEX stable triangle (v2 / v3 / Wombat / Thena stable) | 42_000_000 | atomic | theoretical | +$200–800 per fire on |
| B08-01 | B08    | Thena slisBNB/BNB LP + gauge stake → THE emission farm | 40_000_000 | vote-bribe | theoretical | ~$540 / week ≈ 47 % APR LP+emissions in BNB terms. |
| B08-02 | B08    | veTHE lock → vote highest-bribe gauge → claim bribes | 40_000_000 | vote-bribe | theoretical | see README |
| B08-03 | B08    | PCS v3 USDe/USDT concentrated LP → MasterChef v3 → CAKE farm | 40_000_000 | vote-bribe | theoretical | ~$4 700 / week ≈ 24 % APR. Marginal but stable; the |
| B08-04 | B08    | veTHE + veCAKE cross-protocol bribe basket on slisBNB/BNB | 40_000_000 | vote-bribe | theoretical | see README |
| B08-05 | B08    | PCS + Thena dual-gauge stake on slisBNB/BNB (3-mechanism) | 40_000_000 | vote-bribe | theoretical | see README |
| B08-06 | B08    | veTHE + Pendle YT-THE + Thena LP combo (3-mechanism) | 40_000_000 | vote-bribe | theoretical | see README |
| B08-07 | B08    | Thena bribe-auction front-run on epoch close | 40_000_000 | vote-bribe | theoretical | see README |
| B08-08 | B08    | Stable-pool triple-gauge stack — PCS + Thena + Wombat (3-mechanism) | 40_000_000 | vote-bribe | theoretical | see README |
| B08-09 | B08    | Gauge-weight-shift LP migration Thena ↔ PCS (3-mechanism) | 40_000_000 | vote-bribe | theoretical | see README |
| B09-01 | B09    | USDT/USDC Wombat vs PCS StableSwap flash arb | 45_500_000 | atomic | theoretical | +$500 to +$2,000 per $1M flashed at typical dislocations. |
| B09-02 | B09    | Wombat asset-weight skew large-notional arb vs PCS StableSwap | 45_700_000 | atomic | theoretical | +$100 to +$600 per $250k notional at typical skew. |
| B09-03 | B09    | veWOM lock + Wombat LP boosted-carry positional | 45_000_000 | positional | theoretical | +$6,000 to +$7,500 (LP base + |
| B09-04 | B09    | Wombat slisBNB/BNB dynamic-pool weight-skew arb | 45_800_000 | atomic | theoretical | +$200 to +$1,500 per 1000 WBNB notional at typical |
| B09-05 | B09    | Wombat USDe sidecar pool dynamic-weight skew arb | 46_100_000 | positional | theoretical | +$200 to +$2,000 per $750k notional at typical |
| B09-06 | B09    | Wombat slisBNB sidecar + Lista CDP + PCS Stable lisUSD unwind | 46_000_000 | positional | theoretical | +$0 to +$1,500 per 500 WBNB notional depending on |
| B09-07 | B09    | Wombat asset-weight "nudge" pre-arb (atomic, flash-funded) | 45_900_000 | atomic | theoretical | +$80 to +$300 per 100k |
| B09-08 | B09    | Triangular stable arb across Wombat + PCS Stable + PCS V3 | 46_200_000 | atomic | theoretical | +$200 to +$2,000 per $1M flashed in the favorable |
| B10-01 | B10    | Venus VAI mint vs Lista lisUSD borrow funding-cost basis | 42_000_000 | positional | offline-draft | `notional = $1m`, `hold = 30 days`, `Lista_SF − Venus_VAI_rate |
| B10-02 | B10    | USD1 short-term premium capture via PCS v3 flash | 46_500_000 | positional | offline-draft | `notional = $5_000_000`, atomic premium = 80 bp, total |
| B10-03 | B10    | 5-stable peg-surface scan + triangular atomic arb | 47_000_000 | atomic | offline-draft | logic and verify that the printed atomic PnL matches the modelled |
| B10-04 | B10    | lisUSD ↔ VAI CDP-class basis rotation (sign-flip carry) | 48_000_000 | positional | offline-draft | `notional = $500k`, two 30-day epochs, average spread |
| B10-05 | B10    | VAI + lisUSD + USDe triangular atomic arb (PCS v3 flash) | 47_500_000 | atomic | offline-draft | `notional = $2m`. Synthetic edge prices encode a |
| B10-06 | B10    | USDe + FDUSD + Wombat dynamic-weight basis | 47_800_000 | positional | offline-draft | `notional = $1.5m`, `hold = 36h`. Numbers used in offline: |
| B10-07 | B10    | lisUSD + Pendle PT-lisUSD + Venus borrow loop | 48_200_000 | positional | offline-draft | PnL model (`notional = $1m`, `T = 90d`): |
| B10-08 | B10    | Cross-CDP refinance: USDe short-term borrow vs lisUSD long-term debt | 48_400_000 | positional | offline-draft | PnL model (`slice = $400k`, `T = 21d`, spread = 720 − 480 = 240 bp): |
| B11-01 | B11    | asBNB → Venus → borrow BNB → Astherus re-stake loop | 45_500_000 | positional | theoretical | +1.0–1.7 BNB per 100 |
| B11-02 | B11    | asBNB → Lista Lending → borrow lisUSD → swap → re-stake loop | 45_500_000 | positional | theoretical | `TODO verify`). Expected PnL +1.0–1.4 BNB per 100 BNB over 60 days; |
| B11-03 | B11    | asBNB → Pendle PT/YT split — points decoupling | 45_500_000 | points | theoretical | +1.0–1.4 BNB per 100 BNB over 90 days, with the points |
| B11-04 | B11    | asBNB peg flash arbitrage (Astherus mint × PCS v3) | 45_500_000 | atomic | theoretical | ~+8.5 |
| B11-05 | B11    | asBNB + Lista CDP + Pendle PT-asBNB triple stack | 45_500_000 | positional | theoretical | Expected PnL +1.0–1.5 BNB per 100 BNB over 90 days. Strictly additive |
| B11-06 | B11    | slisBNB + asBNB dual-restake (parallel points farm) | 45_500_000 | points | theoretical | +0.7-1.4 BNB per 100 BNB over 60 days depending on |
| B11-07 | B11    | asBNB + Pendle YT-asBNB + Lista Lending triple | 45_500_000 | points | theoretical | Expected PnL +0.5–1.7 BNB per 100 BNB over 90 days depending on |
| B11-08 | B11    | asBNB → PCS LP (asBNB/WBNB) → Thena gauge triple | 45_500_000 | vote-bribe | theoretical | +2.0–3.5 BNB per 100 BNB |
| B11-09 | B11    | asBNB peg arb via Wombat dynamic-asset-weight pool | 45_500_000 | atomic | theoretical | ~+0.94 BNB ≈ +$564 |
| B12-01 | B12    | solvBTC.BBN → Avalon collateral → borrow USDX → buy more solvBTC.BBN → recursive loop | 46_000_000 | positional | theoretical | +0.8 – 1.2 % over 30 days on 10 BTC principal, |
| B12-02 | B12    | solvBTC ↔ solvBTC.BBN cross-BTC-LSD basis flash arb | 47_200_000 | atomic | theoretical | runs the offline accounting branch). Expected gross PnL per |
| B12-03 | B12    | Avalon USDX peg flash arb (Avalon mint ↔ PCS/Wombat secondary) | 46_500_000 | atomic | theoretical | try/catch around every Avalon and pool resolution). Expected gross |
| B12-04 | B12    | PT-solvBTC.BBN (Pendle BSC) + Avalon collateral stack | 47_500_000 | positional | theoretical | see README |
| B12-05 | B12    | pumpBTC + Avalon + Pendle PT-pumpBTC 3-mech stack | 47_800_000 | positional | theoretical | +1.2 - 1.6 % over |
| B12-06 | B12    | enzoBTC dual-venue basis — Lista Lending vs Avalon | 47_900_000 | positional | theoretical | +0.5 - 0.8 % over |
| B12-07 | B12    | solvBTC in Wombat BTC pool + Avalon collateral 3-mech | 47_600_000 | positional | theoretical | +0.4 - 0.6 % over 30 days on |
| B12-08 | B12    | Avalon BTC-LSD liquidation keeper with cross-DEX exit | 47_700_000 | liquidation | theoretical | ~ $3.6k per $50k liquidation; $30-50k/month avg |
| B12-09 | B12    | Avalon eMode BTC-correlated cross-LSD rotate 3-mech | 47_950_000 | positional | theoretical | +0.8 - 1.3 % |
| B13-01 | B13    | Bridged USDT (LayerZero OFT) vs BSC native USDT discount flash | 45_500_000 | atomic | theoretical | Offline-first PoC; emits `pnl_usd=` block via BSCStrategyBase. |
| B13-02 | B13    | WBETH (BSC bridged ETH-LSD) exchange-rate lag flash arb | 46_500_000 | atomic | theoretical | Offline-first PoC; emits `pnl_usd=` via BSCStrategyBase. |
| B13-03 | B13    | BTCB (BSC-native) vs WBTC (bridged) cross-chain spread arb | 46_800_000 | atomic | theoretical | Offline-first PoC; emits `pnl_usd=` via BSCStrategyBase. |
| B13-04 | B13    | USDe BSC ↔ Ethereum OFT mint/burn roundtrip | 46_900_000 | atomic | theoretical | Offline-first PoC; emits `pnl_usd=` via BSCStrategyBase. |
| B13-05 | B13    | USD1 (WLF) BSC <-> ETH bridge spread | 45_500_000 | atomic | theoretical | see README |
| B13-06 | B13    | CCIP-bridged USDC vs Binance-Peg USDC on BSC | 45_500_000 | atomic | theoretical | see README |
| B13-07 | B13    | deBridge solvBTC BSC <-> Solana arb (3-mechanism) | 45_500_000 | atomic | theoretical | see README |
| B13-08 | B13    | Pendle PT-sUSDe cross-chain (ETH vs BSC) bridge spread | 45_500_000 | atomic | theoretical | see README |
| B14-01 | B14    | vUSDT self-loop — Venus vToken as yield-bearing stablecoin wrapper | 42_500_000 | positional | theoretical | +0.6 – 1.2 % over 30 |
| B14-02 | B14    | vUSDC collateral × vUSDT borrow — wrapper IRM-spread recursion | 42_500_000 | positional | theoretical | +0.9 – 1.4 % over 30 |
| B14-03 | B14    | lisUSD as savings wrapper — Lista Lending recursive carry | 42_500_000 | positional | theoretical | −1.5 % at 30d |
| B14-04 | B14    | Yield-wrapper APY rotation — sUSDe ↔ vUSDT | 42_500_000 | positional | theoretical | +2.0 % over 90 days |
| B14-05 | B14    | sUSDX (Lista savings) + Pendle PT lock + Venus loop — 3-mechanism stack | 42_500_000 | positional | theoretical | +1.0 % over 60 days on 100k USDT |
| B14-06 | B14    | asBNB collateral + Lista lisUSD savings + Venus loop — 3-mech cross-asset | 42_500_000 | positional | theoretical | +0.37 % over 30 days on 60k notional on |
| B14-07 | B14    | Wombat MasterChef LP + veWOM boost + Pendle PT lock — 3-mech | 42_500_000 | positional | theoretical | see README |
| B14-08 | B14    | PT-lisUSD-savings cash-and-carry — BSC variant of F07-08 | 42_000_000 | positional | theoretical | +3.06 % over 180 days on |
| B15-01 | B15    | Lista CDP + Pendle PT-USDe + Venus collateral stack | 42_500_000 | positional | offline-draft | ~$400 net / 30 d / $60 k notional ≈ 8 % |
| B15-02 | B15    | slisBNB · Wombat dynamic LP · Thena gauge bribe stack | 42_600_000 | vote-bribe | offline-draft | +$900 to +$1 200 / 30 d / $30 k notional with |
| B15-03 | B15    | PCS v3 flash + Pendle PT-sUSDe + Venus atomic levered carry | 42_700_000 | atomic | offline-draft | +14 000 USDC over 180 d on |
| B15-04 | B15    | Astherus asBNB · Venus collateral · Pendle YT points stack | 42_800_000 | points | offline-draft | Status: offline-draft / points-class alpha. Cash PnL at fork block: |
| B15-05 | B15    | Lista lisUSD CDP · Wombat · PCS StableSwap cross-stable basis | 42_550_000 | positional | offline-draft | +$1 000 / 30 d / $60 k equity |
| B15-06 | B15    | Avalon solvBTC · Pendle PT-solvBTC · Wombat BTC stable basis | 42_650_000 | positional | offline-draft | +$8 000 / 180 d / $325 k |
| B15-07 | B15    | PCS v3 flash · Astherus asBNB mint · Venus collateral atomic | 42_900_000 | atomic | theoretical | see README |
| B15-08 | B15    | veTHE bribe vote · Pendle YT-asBNB · Venus credit stack | 42_850_000 | vote-bribe | theoretical | see README |
| B15-09 | B15    | Triple-LST restake: slisBNB + BNBx + asBNB on Venus·Lista·Astherus | 42_820_000 | positional | theoretical | see README |
| B15-10 | B15    | Venus VAI mint · Pendle PT-USDT · Wombat stable LP stack | 42_950_000 | positional | theoretical | see README |

---

## Section B — Family roll-up

### B01 — BNB LST 杠杆循环 (8 strategies)

- **Key idea:** slisBNB/BNBx/stkBNB/asBNB recursive borrow on Venus/Lista Lending — borrow native BNB and re-stake to compound leverage.
- **Strategy IDs:** B01-01, B01-02, B01-03, B01-04, B01-05, B01-06, B01-07, B01-08
- **Titles:**
  - `B01-01` — slisBNB → Venus core pool → borrow BNB → Lista re-stake loop
  - `B01-02` — Stader BNBx → Venus isolated pool → borrow BNB → BNBx re-stake loop
  - `B01-03` — ankrBNB → Lista Lending → borrow BNB → Ankr re-stake loop
  - `B01-04` — 50/50 slisBNB + BNBx basket on Venus → borrow BNB → split re-stake
  - `B01-05` — stkBNB (pSTAKE) → Venus → borrow BNB → pSTAKE re-stake loop
  - `B01-06` — slisBNB Venus loop + Pendle PT-slisBNB rate hedge (3-mechanism)
  - `B01-07` — BNBx → Lista Lending → borrow WBNB → Wombat WBNB/BNBx recycle (3-mech)
  - `B01-08` — WBETH (bridged Beacon ETH) → Venus → borrow peg-ETH → re-mint loop

### B02 — BNB LST peg & basis (8 strategies)

- **Key idea:** Atomic single-pool flash arbs between LST internal exchangeRate() and PCS v3 / Thena / Wombat spot.
- **Strategy IDs:** B02-01, B02-02, B02-03, B02-04, B02-05, B02-06, B02-07, B02-08
- **Titles:**
  - `B02-01` — slisBNB / WBNB PancakeSwap v3 single-pool flash arb
  - `B02-02` — BNBx / WBNB Thena ve(3,3) vs Stader internal rate arb
  - `B02-03` — ankrBNB `ratio()` vs PCS v3 spot single-pool flash arb
  - `B02-04` — WBETH (BSC) `exchangeRate()` vs PCS v3 ETH/WBETH spot lag
  - `B02-05` — slisBNB / WBNB PancakeSwap StableSwap dynamic-fee balance-restoration arb
  - `B02-06` — Triangular stkBNB ↔ WBNB ↔ slisBNB cross-LST arb on Wombat + PCS v3 (3-mechanism)
  - `B02-07` — slisBNB PCS v3 flash + Thena solidly-stable swap + Lista internal rate (3-mechanism)
  - `B02-08` — 3-venue atomic MEV-style cycle on slisBNB (PCS v3 + Thena + Wombat, 3-mechanism)

### B03 — Lista lisUSD CDP (8 strategies)

- **Key idea:** lisUSD CDP-mechanism plays: soft-clip auctions, depeg flash, cross-CDP basis, recursive lisUSD mint loops.
- **Strategy IDs:** B03-01, B03-02, B03-03, B03-04, B03-05, B03-06, B03-07, B03-08
- **Titles:**
  - `B03-01` — lisUSD depeg atomic arb via PCS v3 flash + Lista payback
  - `B03-02` — slisBNB · Lista CDP recursive leverage loop
  - `B03-03` — lisUSD ↔ USDe cross-CDP carry basis
  - `B03-04` — lisUSD cross-venue StableSwap arb (PCS v3 ↔ Wombat)
  - `B03-05` — Lista clip-auction keeper (lisUSD -> discounted slisBNB)
  - `B03-06` — Dual-collateral Lista (ETH + slisBNB) → lisUSD → PCS v3 LP
  - `B03-07` — lisUSD → Pendle PT lock + Venus secondary borrow
  - `B03-08` — slisBNB → Lista mint lisUSD → Venus borrow BNB → recursive restake

### B04 — Pendle PT/YT on BSC (9 strategies)

- **Key idea:** BSC-side Pendle PT cash-and-carry + YT point/airdrop speculation on USDe, slisBNB, asBNB markets.
- **Strategy IDs:** B04-01, B04-02, B04-03, B04-04, B04-05, B04-06, B04-07, B04-08, B04-09
- **Titles:**
  - `B04-01` — PT-sUSDe BSC cash-and-carry (fixed-yield to maturity)
  - `B04-02` — PT-slisBNB BSC cash-and-carry (BNB staking yield locked)
  - `B04-03` — YT-slisBNB points speculation (mint PY, sell PT, keep YT)
  - `B04-04` — PT-sUSDe BSC near-maturity redemption arb (4-day carry)
  - `B04-05` — PT-asBNB BSC + Venus collateral + USDT borrow (3-mechanism)
  - `B04-06` — PT-USDe BSC + Lista CDP recursive (3-mechanism)
  - `B04-07` — YT-asBNB Astherus airdrop / points speculation
  - `B04-08` — PT-slisBNB Pendle + Venus collateral + Lista lisUSD borrow (3-mech)
  - `B04-09` — Pendle BSC market PT vs Wombat / PCS spot arb (3-mechanism)

### B05 — Ethena USDe/sUSDe carry (8 strategies)

- **Key idea:** BSC-deployed USDe/sUSDe leveraged on Venus/Lista with funding-rotation and PT-sUSDe variants.
- **Strategy IDs:** B05-01, B05-02, B05-03, B05-04, B05-05, B05-06, B05-07, B05-08
- **Titles:**
  - `B05-01` — sUSDe → Venus collateral → borrow USDT → buy USDe → stake → recursive loop
  - `B05-02` — USDe peg arbitrage — PCS v3 flash → Wombat StableSwap → repay
  - `B05-03` — sUSDe → Lista lending → borrow lisUSD → swap USDe → re-stake loop
  - `B05-04` — Funding-flip rotation — sUSDe ↔ slisBNB (Ethena vs Lista BNB stake)
  - `B05-05` — PT-sUSDe (Pendle) + Lista lending + USDe — 3-mechanism carry
  - `B05-06` — USDe Venus + PCS v3 flash atomic 3-mechanism position-builder
  - `B05-07` — sUSDe + Astherus asBNB + PCS LP — 3-mechanism triangular yield
  - `B05-08` — Ethena Reserve-Fund-related basis anomaly (sUSDe APY mean-reversion)

### B06 — Venus isolated pools (8 strategies)

- **Key idea:** Cross-pool IRM-spread plays inside Venus V4 (Core / LST / Stablecoins) plus VAI mint mechanics + liquidation keepers.
- **Strategy IDs:** B06-01, B06-02, B06-03, B06-04, B06-05, B06-06, B06-07, B06-08
- **Titles:**
  - `B06-01` — Venus Core Pool vs LST isolated pool — USDT supply/borrow rate arb
  - `B06-02` — Venus Core Pool VAI mint + Pancake StableSwap VAI/USDT carry
  - `B06-03` — Venus LST isolated pool — slisBNB high-LTV leveraged loop
  - `B06-04` — VAI depeg — atomic PCS v3 flash + Venus repayVAI arb
  - `B06-05` — Venus liquidation keeper — atomic flash + liquidate + DEX
  - `B06-06` — Cross isolated-pool collateral migration (Venus Core → LST pool)
  - `B06-07` — VAI mint + PCS StableSwap LP + Lista lisUSD CDP — stable trifecta
  - `B06-08` — Venus LST isolated pool — WBETH/WETH eMode-style loop

### B07 — PCS v3 flash + cross-DEX (9 strategies)

- **Key idea:** PancakeSwap v3 single-pool flash bootstraps with Thena vAMM / Wombat / cross-tier arbs (atomic).
- **Strategy IDs:** B07-01, B07-02, B07-03, B07-04, B07-05, B07-06, B07-07, B07-08, B07-09
- **Titles:**
  - `B07-01` — PCS v3 USDT/WBNB 0.01% flash → Thena USDT/WBNB volatile pair arb
  - `B07-02` — PCS v3 BTCB/USDT 0.05% flash → Thena BTCB/USDT volatile arb
  - `B07-03` — PCS v3 CAKE/WBNB 0.25% flash → Thena CAKE/BNB vAMM arb
  - `B07-04` — PCS v3 USDC/USDT 0.01% flash → Wombat USDC→USDT → PCS StableSwap USDT→USDC → repay
  - `B07-05` — PCS v3 ETH/WBNB 0.05% flash → Thena ETH/BNB volatile arb
  - `B07-06` — PCS v3 cross-fee-tier USDT/WBNB micro-spread arb (0.01% vs 0.05% vs 0.25%)
  - `B07-07` — PCS v3 flash → Pendle PT-sUSDe swap → Venus collateral & borrow
  - `B07-08` — PCS v3 USDC flash → Lista lisUSD mint → PCS StableSwap exit
  - `B07-09` — PCS v3 USDC flash + 4-DEX stable triangle (v2 / v3 / Wombat / Thena stable)

### B08 — Thena/PCS ve(3,3) gauge (9 strategies)

- **Key idea:** veTHE / veCAKE / Hidden-Hand BSC bribe-baskets and gauge-vote economics on BSC.
- **Strategy IDs:** B08-01, B08-02, B08-03, B08-04, B08-05, B08-06, B08-07, B08-08, B08-09
- **Titles:**
  - `B08-01` — Thena slisBNB/BNB LP + gauge stake → THE emission farm
  - `B08-02` — veTHE lock → vote highest-bribe gauge → claim bribes
  - `B08-03` — PCS v3 USDe/USDT concentrated LP → MasterChef v3 → CAKE farm
  - `B08-04` — veTHE + veCAKE cross-protocol bribe basket on slisBNB/BNB
  - `B08-05` — PCS + Thena dual-gauge stake on slisBNB/BNB (3-mechanism)
  - `B08-06` — veTHE + Pendle YT-THE + Thena LP combo (3-mechanism)
  - `B08-07` — Thena bribe-auction front-run on epoch close
  - `B08-08` — Stable-pool triple-gauge stack — PCS + Thena + Wombat (3-mechanism)
  - `B08-09` — Gauge-weight-shift LP migration Thena ↔ PCS (3-mechanism)

### B09 — Wombat StableSwap dynamic (8 strategies)

- **Key idea:** Dynamic-asset-weight Wombat plays — weight-skew swaps, vewom boost, cross-DEX stable basis.
- **Strategy IDs:** B09-01, B09-02, B09-03, B09-04, B09-05, B09-06, B09-07, B09-08
- **Titles:**
  - `B09-01` — USDT/USDC Wombat vs PCS StableSwap flash arb
  - `B09-02` — Wombat asset-weight skew large-notional arb vs PCS StableSwap
  - `B09-03` — veWOM lock + Wombat LP boosted-carry positional
  - `B09-04` — Wombat slisBNB/BNB dynamic-pool weight-skew arb
  - `B09-05` — Wombat USDe sidecar pool dynamic-weight skew arb
  - `B09-06` — Wombat slisBNB sidecar + Lista CDP + PCS Stable lisUSD unwind
  - `B09-07` — Wombat asset-weight "nudge" pre-arb (atomic, flash-funded)
  - `B09-08` — Triangular stable arb across Wombat + PCS Stable + PCS V3

### B10 — Cross-stable CDP basis (8 strategies)

- **Key idea:** Cross-stablecoin basis between lisUSD × FDUSD × USDe × USD1 × VAI on Venus/Lista/Wombat.
- **Strategy IDs:** B10-01, B10-02, B10-03, B10-04, B10-05, B10-06, B10-07, B10-08
- **Titles:**
  - `B10-01` — Venus VAI mint vs Lista lisUSD borrow funding-cost basis
  - `B10-02` — USD1 short-term premium capture via PCS v3 flash
  - `B10-03` — 5-stable peg-surface scan + triangular atomic arb
  - `B10-04` — lisUSD ↔ VAI CDP-class basis rotation (sign-flip carry)
  - `B10-05` — VAI + lisUSD + USDe triangular atomic arb (PCS v3 flash)
  - `B10-06` — USDe + FDUSD + Wombat dynamic-weight basis
  - `B10-07` — lisUSD + Pendle PT-lisUSD + Venus borrow loop
  - `B10-08` — Cross-CDP refinance: USDe short-term borrow vs lisUSD long-term debt

### B11 — Astherus asBNB restake (9 strategies)

- **Key idea:** asBNB on Venus/Lista plus underlying Astherus restake, plus Pendle PT/YT points splits.
- **Strategy IDs:** B11-01, B11-02, B11-03, B11-04, B11-05, B11-06, B11-07, B11-08, B11-09
- **Titles:**
  - `B11-01` — asBNB → Venus → borrow BNB → Astherus re-stake loop
  - `B11-02` — asBNB → Lista Lending → borrow lisUSD → swap → re-stake loop
  - `B11-03` — asBNB → Pendle PT/YT split — points decoupling
  - `B11-04` — asBNB peg flash arbitrage (Astherus mint × PCS v3)
  - `B11-05` — asBNB + Lista CDP + Pendle PT-asBNB triple stack
  - `B11-06` — slisBNB + asBNB dual-restake (parallel points farm)
  - `B11-07` — asBNB + Pendle YT-asBNB + Lista Lending triple
  - `B11-08` — asBNB → PCS LP (asBNB/WBNB) → Thena gauge triple
  - `B11-09` — asBNB peg arb via Wombat dynamic-asset-weight pool

### B12 — Avalon BTC-LSD (9 strategies)

- **Key idea:** solvBTC.BBN / pumpBTC / enzoBTC on Avalon Finance — recursive BTC leverage, USDX peg arbs, Pendle PT stacks.
- **Strategy IDs:** B12-01, B12-02, B12-03, B12-04, B12-05, B12-06, B12-07, B12-08, B12-09
- **Titles:**
  - `B12-01` — solvBTC.BBN → Avalon collateral → borrow USDX → buy more solvBTC.BBN → recursive loop
  - `B12-02` — solvBTC ↔ solvBTC.BBN cross-BTC-LSD basis flash arb
  - `B12-03` — Avalon USDX peg flash arb (Avalon mint ↔ PCS/Wombat secondary)
  - `B12-04` — PT-solvBTC.BBN (Pendle BSC) + Avalon collateral stack
  - `B12-05` — pumpBTC + Avalon + Pendle PT-pumpBTC 3-mech stack
  - `B12-06` — enzoBTC dual-venue basis — Lista Lending vs Avalon
  - `B12-07` — solvBTC in Wombat BTC pool + Avalon collateral 3-mech
  - `B12-08` — Avalon BTC-LSD liquidation keeper with cross-DEX exit
  - `B12-09` — Avalon eMode BTC-correlated cross-LSD rotate 3-mech

### B13 — Cross-chain LST/stable (8 strategies)

- **Key idea:** LayerZero OFT / CCIP / deBridge BSC↔ETH/Sol bridge spreads and round-trip mint-burn flashes.
- **Strategy IDs:** B13-01, B13-02, B13-03, B13-04, B13-05, B13-06, B13-07, B13-08
- **Titles:**
  - `B13-01` — Bridged USDT (LayerZero OFT) vs BSC native USDT discount flash
  - `B13-02` — WBETH (BSC bridged ETH-LSD) exchange-rate lag flash arb
  - `B13-03` — BTCB (BSC-native) vs WBTC (bridged) cross-chain spread arb
  - `B13-04` — USDe BSC ↔ Ethereum OFT mint/burn roundtrip
  - `B13-05` — USD1 (WLF) BSC <-> ETH bridge spread
  - `B13-06` — CCIP-bridged USDC vs Binance-Peg USDC on BSC
  - `B13-07` — deBridge solvBTC BSC <-> Solana arb (3-mechanism)
  - `B13-08` — Pendle PT-sUSDe cross-chain (ETH vs BSC) bridge spread

### B14 — Yield-bearing stable loop (8 strategies)

- **Key idea:** vUSDT / vUSDC / sUSDe / sUSDX / Lista lisUSD savings recursive farms — pure stable carry.
- **Strategy IDs:** B14-01, B14-02, B14-03, B14-04, B14-05, B14-06, B14-07, B14-08
- **Titles:**
  - `B14-01` — vUSDT self-loop — Venus vToken as yield-bearing stablecoin wrapper
  - `B14-02` — vUSDC collateral × vUSDT borrow — wrapper IRM-spread recursion
  - `B14-03` — lisUSD as savings wrapper — Lista Lending recursive carry
  - `B14-04` — Yield-wrapper APY rotation — sUSDe ↔ vUSDT
  - `B14-05` — sUSDX (Lista savings) + Pendle PT lock + Venus loop — 3-mechanism stack
  - `B14-06` — asBNB collateral + Lista lisUSD savings + Venus loop — 3-mech cross-asset
  - `B14-07` — Wombat MasterChef LP + veWOM boost + Pendle PT lock — 3-mech
  - `B14-08` — PT-lisUSD-savings cash-and-carry — BSC variant of F07-08

### B15 — Tri-protocol mechanism stack (10 strategies)

- **Key idea:** Every PoC explicitly composes ≥3 distinct BSC primitives in a single trade or position.
- **Strategy IDs:** B15-01, B15-02, B15-03, B15-04, B15-05, B15-06, B15-07, B15-08, B15-09, B15-10
- **Titles:**
  - `B15-01` — Lista CDP + Pendle PT-USDe + Venus collateral stack
  - `B15-02` — slisBNB · Wombat dynamic LP · Thena gauge bribe stack
  - `B15-03` — PCS v3 flash + Pendle PT-sUSDe + Venus atomic levered carry
  - `B15-04` — Astherus asBNB · Venus collateral · Pendle YT points stack
  - `B15-05` — Lista lisUSD CDP · Wombat · PCS StableSwap cross-stable basis
  - `B15-06` — Avalon solvBTC · Pendle PT-solvBTC · Wombat BTC stable basis
  - `B15-07` — PCS v3 flash · Astherus asBNB mint · Venus collateral atomic
  - `B15-08` — veTHE bribe vote · Pendle YT-asBNB · Venus credit stack
  - `B15-09` — Triple-LST restake: slisBNB + BNBx + asBNB on Venus·Lista·Astherus
  - `B15-10` — Venus VAI mint · Pendle PT-USDT · Wombat stable LP stack

---

## Section C — Filter views

### C.1 — Top 10 by midpoint expected PnL (normalized to 30-day USD)

Heuristic: parse `+X–Y` or `$X–Y` from the README's expected-PnL phrase, take midpoint, and (for BNB-denominated carries) multiply by ~$650/BNB. Atomic per-ticket numbers are treated as a single 30-day opportunity. Bps figures are normalised to $1M notional. See footnote.

| Rank | ID | Family | Title | Estimated 30d USD | Source |
| ---- | -- | ------ | ----- | ----------------- | ------ |
| 1 | B12-08 | B12 | Avalon BTC-LSD liquidation keeper with cross-DEX exit | $25,015 | atomic-ticket |
| 2 | B06-02 | B06 | Venus Core Pool VAI mint + Pancake StableSwap VAI/USDT carry | $6,005 | atomic-ticket |
| 3 | B04-09 | B04 | Pendle BSC market PT vs Wombat / PCS spot arb (3-mechanism) | $5,000 | bps |
| 4 | B04-05 | B04 | PT-asBNB BSC + Venus collateral + USDT borrow (3-mechanism) | $3,000 | atomic-ticket |
| 5 | B04-08 | B04 | PT-slisBNB Pendle + Venus collateral + Lista lisUSD borrow (3-mech) | $2,502 | atomic-ticket |
| 6 | B06-01 | B06 | Venus Core Pool vs LST isolated pool — USDT supply/borrow rate arb | $1,950 | atomic-ticket |
| 7 | B11-08 | B11 | asBNB → PCS LP (asBNB/WBNB) → Thena gauge triple | $1,788 | 30d BNB carry |
| 8 | B02-08 | B02 | 3-venue atomic MEV-style cycle on slisBNB (PCS v3 + Thena + Wombat, 3-mechanism) | $1,740 | atomic-ticket |
| 9 | B02-06 | B02 | Triangular stkBNB ↔ WBNB ↔ slisBNB cross-LST arb on Wombat + PCS v3 (3-mechanism | $1,000 | atomic-ticket |
| 10 | B02-07 | B02 | slisBNB PCS v3 flash + Thena solidly-stable swap + Lista internal rate (3-mechan | $1,000 | atomic-ticket |

### C.2 — Top 10 atomic strategies

| Rank | ID | Family | Title | Est. per-opp USD | Block |
| ---- | -- | ------ | ----- | ---------------- | ----- |
| 1 | B04-09 | B04 | Pendle BSC market PT vs Wombat / PCS spot arb (3-mechanism) | $5,000 | 44_000_000 |
| 2 | B06-01 | B06 | Venus Core Pool vs LST isolated pool — USDT supply/borrow rate arb | $1,950 | 42_500_000 |
| 3 | B02-08 | B02 | 3-venue atomic MEV-style cycle on slisBNB (PCS v3 + Thena + Wombat, 3- | $1,740 | 45_400_000 |
| 4 | B02-06 | B02 | Triangular stkBNB ↔ WBNB ↔ slisBNB cross-LST arb on Wombat + PCS v3 (3 | $1,000 | 45_200_000 |
| 5 | B02-07 | B02 | slisBNB PCS v3 flash + Thena solidly-stable swap + Lista internal rate | $1,000 | 45_300_000 |
| 6 | B02-05 | B02 | slisBNB / WBNB PancakeSwap StableSwap dynamic-fee balance-restoration | $650 | 45_100_000 |
| 7 | B07-05 | B07 | PCS v3 ETH/WBNB 0.05% flash → Thena ETH/BNB volatile arb | $600 | 42_000_000 |
| 8 | B07-08 | B07 | PCS v3 USDC flash → Lista lisUSD mint → PCS StableSwap exit | $550 | 42_000_000 |
| 9 | B07-09 | B07 | PCS v3 USDC flash + 4-DEX stable triangle (v2 / v3 / Wombat / Thena st | $500 | 42_000_000 |
| 10 | B07-02 | B07 | PCS v3 BTCB/USDT 0.05% flash → Thena BTCB/USDT volatile arb | $325 | 42_000_000 |

### C.3 — Top 10 positional strategies

| Rank | ID | Family | Title | Est. 30d USD | Block |
| ---- | -- | ------ | ----- | ------------ | ----- |
| 1 | B06-02 | B06 | Venus Core Pool VAI mint + Pancake StableSwap VAI/USDT carry | $6,005 | 42_500_000 |
| 2 | B04-05 | B04 | PT-asBNB BSC + Venus collateral + USDT borrow (3-mechanism) | $3,000 | 44_500_000 |
| 3 | B04-08 | B04 | PT-slisBNB Pendle + Venus collateral + Lista lisUSD borrow (3-mech) | $2,502 | 44_000_000 |
| 4 | B11-05 | B11 | asBNB + Lista CDP + Pendle PT-asBNB triple stack | $812 | 45_500_000 |
| 5 | B11-02 | B11 | asBNB → Lista Lending → borrow lisUSD → swap → re-stake loop | $780 | 45_500_000 |
| 6 | B01-01 | B01 | slisBNB → Venus core pool → borrow BNB → Lista re-stake loop | $358 | 40_000_000 |
| 7 | B01-06 | B01 | slisBNB Venus loop + Pendle PT-slisBNB rate hedge (3-mechanism) | $358 | 42_000_000 |
| 8 | B01-07 | B01 | BNBx → Lista Lending → borrow WBNB → Wombat WBNB/BNBx recycle (3-mech) | $358 | 41_500_000 |
| 9 | B01-03 | B01 | ankrBNB → Lista Lending → borrow BNB → Ankr re-stake loop | $292 | 41_000_000 |
| 10 | B05-03 | B05 | sUSDe → Lista lending → borrow lisUSD → swap USDe → re-stake loop | $165 | 42_500_000 |

### C.4 — Top 10 three-mechanism stacks

Filtered by README keyword `3-mech` / `triple` / `≥3 mechanism`, ranked by keyword-density × mechanism-count. The B15 family is by-construction `≥3 mechanisms`, so it dominates the head of the list.

| Rank | ID | Family | Title | 3-mech hits | Mech count |
| ---- | -- | ------ | ----- | ----------- | ---------- |
| 1 | B15-06 | B15 | Avalon solvBTC · Pendle PT-solvBTC · Wombat BTC stable basis | 5 | 3 |
| 2 | B02-06 | B02 | Triangular stkBNB ↔ WBNB ↔ slisBNB cross-LST arb on Wombat + PCS v3 (3-mechanism | 3 | 3 |
| 3 | B02-08 | B02 | 3-venue atomic MEV-style cycle on slisBNB (PCS v3 + Thena + Wombat, 3-mechanism) | 3 | 3 |
| 4 | B05-05 | B05 | PT-sUSDe (Pendle) + Lista lending + USDe — 3-mechanism carry | 3 | 3 |
| 5 | B12-05 | B12 | pumpBTC + Avalon + Pendle PT-pumpBTC 3-mech stack | 3 | 3 |
| 6 | B15-01 | B15 | Lista CDP + Pendle PT-USDe + Venus collateral stack | 3 | 3 |
| 7 | B15-02 | B15 | slisBNB · Wombat dynamic LP · Thena gauge bribe stack | 3 | 3 |
| 8 | B15-04 | B15 | Astherus asBNB · Venus collateral · Pendle YT points stack | 3 | 3 |
| 9 | B15-09 | B15 | Triple-LST restake: slisBNB + BNBx + asBNB on Venus·Lista·Astherus | 3 | 0 |
| 10 | B12-09 | B12 | Avalon eMode BTC-correlated cross-LSD rotate 3-mech | 2 | 4 |

---

**Sorting footnote.** The Section C ranking is a *coarse* heuristic. Most BSC PoCs are pinned to `theoretical` status without an archive-RPC replay, so the dollar figures are read out of each README's PnL paragraph and converted with these rules:

- Pure-dollar windows `$X–$Y` (atomic per-ticket) → midpoint, treated as a single 30-day opportunity.
- BNB-denominated carries `X–Y BNB / N BNB / 30 days` → midpoint × ~$650/BNB.
- Basis-point payoffs `X–Y bps` → midpoint × $100/bp on a $1M notional.
- Percent windows `X%–Y%` → midpoint × $10,000 (i.e. % of a $1M reference book).
- Strategies whose README left the PnL paragraph open (`see README`) are not ranked.

These are *order-of-magnitude* numbers only; the per-strategy README is the authoritative source.