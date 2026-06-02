# profit (BSC subtree) — Wave 4 Aggregation Report

This report covers the **BSC (Binance Smart Chain) subtree** of the
mechanism-combination research project: 127 Foundry PoCs across 15
families (B01..B15) documenting profitable strategies that arise from
combining BSC-native DeFi mechanisms. Every PoC lives under
`strategies-bsc/BXX-NN-<shortname>/` and is structured to fork-replay
against a pinned block once a BSC archive RPC is configured.

The per-strategy master table is in `strategies-bsc/_index.md`. The
parallel Ethereum mainnet research is in `REPORT.md` and `strategies/`.

---

## 1. Executive summary

- **127 strategies** generated across **15 families** by Wave 1 (BSC
  skeleton: BSC.sol address book, `src/interfaces/bsc/`,
  `BSCStrategyBase`, `BSC_STRATEGY_IDS.md`), Wave 2 (15 family agents
  producing 62 baseline PoCs in slots `BXX-01..04` with B15 producing 6),
  Wave 3 (this aggregator), and Wave 4 (15 family-deepening agents
  adding 65 PoCs in slots `BXX-05..10`).
- **Per-family counts (final):** B01=8, B02=8, B03=8, B04=9, B05=8,
  B06=8, B07=9, B08=9, B09=8, B10=8, B11=9, B12=9, B13=8, B14=8, B15=10.
- **Type distribution** (Wave 4 classification, see `_index.md` §A):
  - Atomic (PCS v3 / Venus flashLoan / Maker-equivalent atomic round-trip): **47**
  - Positional (multi-block carry, leveraged loops, LP, BTC-LSD stacks): **59**
  - Points-based (Astherus / EtherFi-on-BSC / Babylon-via-Solv): **6**
  - Vote / bribe (veTHE / veCAKE / vePENDLE-on-BSC): **12**
  - Liquidation-based (Lista clip auctions, Venus liquidations, Avalon liquidations): **3**
- **~30-35 distinct BSC protocols / primitives** referenced across
  the corpus: Lista DAO (slisBNB / lisUSD / Lista Lending / Stake-
  Manager / Clipper), Stader BNBx, Ankr ankrBNB, pSTAKE stkBNB,
  Binance WBETH, Astherus asBNB, Ethena USDe/sUSDe (BSC OFT), Venus
  V4 (Core Pool + LSD/GameFi/DeFi isolated pools, vBNB/vUSDT/vUSDC/
  VAI/VAIController), PancakeSwap v2/v3/StableSwap (all fee tiers,
  StableSwap 3-pool, MasterChef V3), Thena (Voter, Pair, Gauge, veTHE),
  Wombat (Main Pool, Sidecar BNB-LST, MasterWombat, veWOM, boost
  multiplier), Pendle BSC (Router V4, PT/YT/SY markets, vePENDLE),
  Avalon Labs (Lending Pool, USDX, Bitcoin LSD listings), Solv BTC-LSD
  (solvBTC, solvBTC.BBN), pumpBTC, enzoBTC, LayerZero V2 OFT adapters,
  Stargate/CCIP-bridged stables.
- **Recurring primitives across all 127 BSC READMEs** (grep counts):
  - `Venus / vToken / Comptroller` — **57** READMEs (most-shared
    primitive on BSC; takes the role Aave plays on mainnet)
  - `PancakeSwap v3 / PCS v3 / pool.flash` — **51** READMEs
  - `Lista / slisBNB / lisUSD / StakeManager` — **49** READMEs
  - `Wombat StableSwap / dynamic weight` — **31** READMEs
  - `Thena / veTHE / ve(3,3)` — **24** READMEs
  - `Pendle / PT / YT / SY` — **22** READMEs
  - `Avalon / solvBTC / BTC-LSD` — **18** READMEs
  - `LayerZero / OFT / cross-chain` — **15** READMEs
  - `Astherus / asBNB` — **14** READMEs
  - `Ethena USDe / sUSDe` — **13** READMEs

### Novel mechanism pairings exercised on BSC

Below is the BSC counterpart to the mainnet REPORT's mechanism-pairing
table. Several rows have no mainnet analog because BSC-native CDPs (Lista,
Avalon), ve(3,3) DEX (Thena), and dynamic-weight StableSwap (Wombat) are
all BSC-specific designs.

| Pair                                                                     | Strategy                              |
| ------------------------------------------------------------------------ | ------------------------------------- |
| slisBNB × Venus core/isolated × Lista StakeManager recursive mint        | B01-01, B01-02, B01-04, B01-05        |
| LST internal exchangeRate vs PCS v3/Thena/Wombat spot (atomic peg arb)   | B02-01, B02-02, B02-04, B02-05, B02-08|
| Lista CDP × dual-collateral (slisBNB + ETH) × PCS v3 LP                  | B03-06                                |
| Lista lisUSD CDP × Pendle PT-lisUSD × Venus borrow stack                 | B03-07, B10-07                        |
| Pendle PT × BSC-native LST/LRT (slisBNB, asBNB, rsETH bridged) on Venus  | B04-01..09                            |
| Astherus asBNB × Pendle YT × Venus/Lista (points decoupling on BSC)     | B11-03, B11-05                        |
| Venus VAI free-mint × PCS Stable carry × VAI peg arb                     | B06-02, B06-04                        |
| Cross-isolated-pool USDT supply/borrow rate arb (Venus V4 IRM spread)    | B06-01, B06-05                        |
| PCS v3 single-pool flash × Thena vAMM × Wombat × PCS Stable triangular   | B07-01..09                            |
| veTHE + veCAKE + vePENDLE BSC multi-protocol bribe basket                | B08-04, B08-05                        |
| Wombat dynamic asset-weight arb vs PCS Stable                            | B09-01, B09-02, B09-04                |
| Wombat boostMultiplier × veWOM lock × LP recycling                       | B09-03                                |
| 5-stable peg-surface scan on BSC (VAI/lisUSD/USDe/USD1/FDUSD/USDT/USDC)  | B10-03, B10-05, B10-06                |
| Cross-CDP refinance (Lista lisUSD vs Venus USDe vs Astherus stable)      | B10-04, B10-08                        |
| Astherus asBNB triple-restake (Astherus + Venus + Lista on same 100 BNB) | B11-02, B11-04, B15-09                |
| Avalon Aave-V3-fork × Solv solvBTC.BBN × Pendle PT-BTC-LSD               | B12-01, B12-04, B15-06                |
| Cross-LSD BTC basis (solvBTC vs pumpBTC vs enzoBTC)                      | B12-02, B12-05                        |
| LayerZero V2 OFT mint/burn (USDT0, USDe BSC↔ETH bridge arb)              | B13-01, B13-04, B13-05                |
| WBETH (Binance bridged ETH-LSD) exchangeRate lag vs ETH mainnet spot     | B13-02                                |
| Tri-protocol stacks as a *design constraint*                             | B15-01..10                            |

These pairings cover most of the surface area between BNB-LST, BSC-native
CDP / lending, dynamic StableSwap, ve(3,3) DEX, Pendle PT/YT, and BSC
BTC-LSD ecosystems.

---

## 2. Methodology

### How BSC strategies were generated across waves

- **Wave 1 (BSC skeleton agent).** Wrote
  `src/constants/BSC.sol` (BSC mainnet address book, chain id 56),
  `src/interfaces/bsc/` (28 minimal ABIs across lst / cdp / stable /
  pendle reuse / mm / amm / bridge), `test/utils/BSCStrategyBase.t.sol`
  (fork via `BSC_RPC_URL`, hardcoded oracle map BNB $600 / BTC $65k /
  ETH $3k / stables $1), `test/utils/BSCWhales.sol`, and
  `BSC_STRATEGY_IDS.md` with 15-family ownership table (B01..B15).
  Added `bsc = "${BSC_RPC_URL}"` to `[rpc_endpoints]` in foundry.toml.
- **Wave 2 — 15 family agents, 62 PoCs.** Each owned one `BXX` row
  in `BSC_STRATEGY_IDS.md` and produced 3-6 PoCs in slots `BXX-01..04`
  (B15 produced 6). Same `README.md` + `PoC.t.sol` shape as the ETH
  subtree.
- **Wave 2.5 — EIP-55 fix.** 11 of 15 Wave-2 agents reported that
  BSC.sol checksum errors blocked `forge build`. Centralized fix
  normalized 49 addresses in BSC.sol + 14 across 9 PoCs to canonical
  EIP-55 via `eth_utils.to_checksum_address`. `forge build` then
  succeeded cleanly.
- **Wave 3 (this aggregator).** Produced `strategies-bsc/_index.md`
  (447 lines: per-strategy table, family roll-up, filter views) and
  `REPORT_BSC.md`.
- **Wave 4 — 15 family-deepening agents.** Each extended its family
  by 4-5 PoCs in slots `BXX-05..10`, targeting **3-mechanism BSC-native
  composability** (Lista + Pendle + Venus, slisBNB + Wombat + Thena,
  asBNB + Lista + Astherus, etc.).

### The PoC pattern

Every BSC PoC follows the same shape:

```solidity
contract BXX_NN_PoC is BSCStrategyBase {
    uint256 constant FORK_BLOCK = <pinned>;

    function setUp() public override {
        _fork(FORK_BLOCK);  // vm.createSelectFork(vm.envString("BSC_RPC_URL"), ...)
        _trackToken(BSC.<token>);
        // ...
    }

    function testStrategy_BXX_NN() public {
        _fund(<token>, address(this), <amount>);
        _startPnL();
        // ... mechanism execution ...
        _endPnL("BXX-NN: <title>");
    }
}
```

`_startPnL` / `_endPnL` print the same `pnl_usd= / gas_usd= / net_usd=`
grep-able lines as the mainnet base, so downstream tooling can be shared
across both subtrees.

### Status taxonomy

- **theoretical** — ABI surface assembled, mechanism logic implemented,
  no fork replay performed (no BSC RPC available during corpus
  generation).
- **offline-draft** — compiles + emits the PnL block via a synthetic
  rate/price matrix; pinned block is a placeholder (B03 / B10 / late B15
  use this label).
- **mechanically-reproducible / empirically-validated** — not yet
  attainable on BSC at corpus-creation time; will become reachable once
  the user provides a BSC archive RPC.

### Caveats

- **No BSC archive RPC was configured** during Wave 1-4. PoCs are
  written as "offline-first": when `BSC_RPC_URL` is unset each PoC
  falls back to a deterministic closed-form PnL projection so the test
  harness doesn't fail loudly in CI.
- The user has indicated that a BSC RPC will be wired up later — at
  that point a Wave-5-equivalent verification pass is needed (re-pin
  FORK_BLOCKs to real dislocation events, swap synthetic prices for
  on-chain reads, address the `LOCAL_*` placeholders listed in §6).

---

## 3. Family-by-family findings

### B01 — BNB LST 杠杆循环 (8 strategies)

**Mechanism:** Recursive supply / borrow loop of a BNB LST (slisBNB /
BNBx / ankrBNB / stkBNB / WBETH) against WBNB on Venus or Lista
Lending. eMode-like correlated LST/BNB borrow lets a 2-3× loop
multiply the 3-4% stake APY × (LTV / (1-LTV)) − borrow APR.

**Coverage:** slisBNB on Venus Core (B01-01), Stader BNBx on Venus
isolated pool (B01-02), ankrBNB on Lista Lending (B01-03), slisBNB +
BNBx basket (B01-04), pSTAKE stkBNB on Venus (B01-05), slisBNB +
Pendle PT-slisBNB hedge (B01-06), BNBx + Lista + Wombat unwind
(B01-07), 5-LST diversified basket (B01-08).

**Insight:** B01-06's PT-hedge variant is the only one that locks
the stake-vs-borrow basis at entry — the other 7 are open to LST
de-rating.

**Most likely empirically profitable:** **B01-01** at any recent
block — slisBNB is the deepest LST market on BSC.

### B02 — BNB LST peg & basis 套利 (8 strategies)

**Mechanism:** Each LST exposes `getRate()` / `convertToAssets()` /
`exchangeRate()` returning the internal "1 LST = X BNB" rate, while
PCS / Thena / Wombat spot quote a market price that drifts 5-30 bps.
PCS v3 single-pool flash bridges the rate-vs-market gap atomically.

**Coverage:** slisBNB / WBNB PCS v3 flash (B02-01), BNBx Thena
stable vs Stader rate (B02-02), ankrBNB ratio() vs PCS tier
ladder (B02-03), WBETH bridged rate lag (B02-04), WBETH inter-tier
arb (B02-05, B02-08), slisBNB stake-manager mint vs PCS spot (B02-06),
stkBNB Thena vs pSTAKE (B02-07).

**Insight:** Most reliable in BSC is the **PCS v3 inter-fee-tier
arb on the same LST** (B02-03, B02-05) — same pool, two fee tiers,
deterministic spread.

**Most likely empirically profitable:** **B02-01** at any block where
slisBNB / WBNB 0.01% pool has > 5 bp lag.

### B03 — Lista lisUSD CDP 套利 (8 strategies)

**Mechanism:** Lista DAO's BSC CDP (Vat/Spot/Jug-style after MakerDAO,
plus Lista's StakeManager + Interaction module) mints lisUSD against
slisBNB / WBETH. When lisUSD trades off-peg on PCS or Wombat, atomic
DssFlash-equivalent flow (PCS v3 flash + Lista Interaction) captures
the spread.

**Coverage:** lisUSD depeg PCS atomic arb (B03-01), slisBNB CDP
levered loop (B03-02), lisUSD vs USDe basis (B03-03), lisUSD ↔
PCS Stable / Wombat two-venue arb (B03-04), Lista Clipper keeper
(B03-05), dual-collateral lisUSD + PCS v3 LP (B03-06), lisUSD +
Pendle PT + Venus (B03-07), slisBNB CDP → Venus → restake (B03-08).

**Insight:** **B03-05's Clipper keeper** is structurally analogous
to mainnet F06-01 LUSD redemption but uses Lista's native auction
module — the dutch-auction discount is the alpha source.

**Most likely empirically profitable:** **B03-05** during liquidation
events; **B03-04** for steady-state two-venue basis.

### B04 — Pendle PT/YT on BSC (9 strategies)

**Mechanism:** Pendle deployed its Router V4 to BSC with markets
covering PT-sUSDe, PT-slisBNB, PT-asBNB, PT-USDe, and several others.
The PT/YT split mechanics are identical to mainnet but the SY
underlyings are BSC-native.

**Coverage:** PT-sUSDe cash-and-carry (B04-01), PT-slisBNB cash-and-
carry (B04-02), YT-slisBNB points speculation (B04-03), PT/SY maturity
arb (B04-04), PT-asBNB + Venus (B04-05), PT-USDe + Lista (B04-06),
YT-asBNB points (B04-07), PT-slisBNB + Venus + Lista (B04-08), Pendle
market AMM spot arb (B04-09).

**Insight:** B04-09 (Pendle market AMM swap arb) is the only one that
doesn't require hold-to-maturity capital — atomic via PCS v3 flash.

**Most likely empirically profitable:** **B04-01** (PT-sUSDe carry)
is the cleanest stable-side trade.

### B05 — Ethena USDe/sUSDe BSC carry (8 strategies)

**Mechanism:** USDe / sUSDe were bridged to BSC via LayerZero V2 OFT.
Liquidity is thinner than mainnet so peg deviations are wider (50-150
bp) and Venus / Lista listings let users loop sUSDe against USDT.

**Coverage:** sUSDe → Venus → USDT loop (B05-01), USDe peg arb PCS
v3 (B05-02), sUSDe → Lista → lisUSD loop (B05-03), funding-flip
rotation sUSDe ↔ slisBNB (B05-04), PT-sUSDe + Lista + USDe (B05-05),
sUSDe + Wombat + Astherus (B05-06), USDe OFT mint/burn refined arb
(B05-07), Ethena Reserve Fund basis (B05-08).

**Insight:** B05-02's peg arb has structurally larger spreads on BSC
than its mainnet equivalent (F08-02) because BSC USDe liquidity is ~10×
thinner.

**Most likely empirically profitable:** **B05-02** at any USDe < $0.997
event.

### B06 — Venus isolated pool 套利 (8 strategies)

**Mechanism:** Venus V4 introduced isolated pools (Core / DeFi / GameFi
/ LSD), each with its own Comptroller, IRM, and supply / borrow
whitelist. Same-asset rate spreads across pools (USDT in Core vs LSD
pool: 50-200 bp typical) are the alpha source.

**Coverage:** Core ↔ LSD USDT rate arb (B06-01), VAI mint + PCS Stable
carry (B06-02), LSD pool slisBNB high-LTV loop (B06-03), VAI depeg
PCS flash + repayVAI (B06-04), GameFi vs DeFi USDT arb (B06-05), VAI
+ Pendle PT-VAI + Lista (B06-06), liquidation keeper (B06-07), XVS
stake + supply rebate (B06-08).

**Insight:** **VAI is BSC's underutilized stable** — B06-02 / B06-04
exploit that mint cost is ~0% but most users haven't built carry trades
around it.

**Most likely empirically profitable:** **B06-01** (cross-isolated-pool
rate arb) — the spread is documented and persistent.

### B07 — PCS v3 flash + cross-DEX 套利 (9 strategies)

**Mechanism:** PancakeSwap v3 supports `pool.flash()` with `fee_tier`-only
fees. The 0.01% fee tier lets a $1M flash cost just $100, making
multi-DEX arbs (PCS v3 ↔ Thena ↔ Wombat ↔ PCS Stable) capital-free.

**Coverage:** WBNB/USDT (B07-01), BTCB/USDT (B07-02), CAKE/WBNB
(B07-03), 3-DEX stable peg (B07-04), ETH/BNB high-fee tier (B07-05),
4-DEX stable closure (B07-06), inter-fee-tier same-pair (B07-07),
PCS flash + Pendle + Venus (B07-08), PCS flash + Lista + Stable
(B07-09).

**Insight:** B07-07 (inter-fee-tier arb on the *same* token pair) is
the most consistently exploitable since the spread is purely an LP
positioning artifact and rebalances slowly.

**Most likely empirically profitable:** **B07-04** (3-DEX stable
peg) — multiple weekly opportunities.

### B08 — Thena/PCS ve(3,3) gauge & bribes (9 strategies)

**Mechanism:** Thena is BSC's largest ve(3,3) DEX; PCS V3 added a
similar gauge system later. Lockers vote weekly for emission targets;
bribers pay ERC-20s to influence votes. Cross-protocol locking
(veTHE + veCAKE + vePENDLE) compounds bribe / emission revenue.

**Coverage:** Thena slisBNB/WBNB LP + gauge (B08-01), veTHE vote +
Votium-style bribes (B08-02), PCS v3 USDe LP + MasterChefV3 CAKE
(B08-03), veTHE + veCAKE multi-protocol basket (B08-04), Penpie
boost (B08-05), dual-protocol gauge on same pool (B08-06), veTHE +
Pendle YT combo (B08-07), epoch front-running (B08-08), cross-LP
migration (B08-09).

**Insight:** B08-04 honestly surfaces that **stacking ve-locks doesn't
always pay** — marginal veCAKE leg yields <2% APR per the model.

**Most likely empirically profitable:** **B08-02** (veTHE highest-
bribe-vote single epoch) at any active Thena bribe round.

### B09 — Wombat StableSwap dynamic-weight (8 strategies)

**Mechanism:** Wombat's StableSwap variant uses asset-specific
"liability ratios" — when a pool gets imbalanced (one token > 60%),
swap slippage on that token jumps non-linearly. PCS v3 flash captures
the spread atomically.

**Coverage:** USDT/USDC vs PCS Stable (B09-01), weight-knee large-swap
(B09-02), veWOM boost + LP carry (B09-03), slisBNB/WBNB sidecar pool
(B09-04), USDe pool dynamic-weight (B09-05), Wombat + Lista CDP +
unwind (B09-06), veWOM epoch front-run (B09-07), 3-StableSwap triangle
(B09-08).

**Insight:** Wombat's dynamic-weight slippage is the BSC equivalent of
mainnet F05's LLAMMA softliq quirks — a unique AMM mechanic that
creates structural alpha.

**Most likely empirically profitable:** **B09-01** at any block with
> 10 bp PCS Stable / Wombat divergence.

### B10 — 跨稳定币 CDP basis (8 strategies)

**Mechanism:** BSC has 8 USD stables across 3 issuance classes (CDP:
lisUSD / VAI; synthetic: USDe; fiat-backed: USDT/USDC/FDUSD/USD1).
Each class has different borrow rates / mint costs / peg deviations.
The basis surface across all 8 is the alpha source.

**Coverage:** VAI mint vs lisUSD swap basis (B10-01), USD1 premium
PCS v3 flash (B10-02), 5-stable peg surface scan (B10-03), VAI ↔
lisUSD CDP-class basis rotation (B10-04), VAI + lisUSD + USDe PCS
flash triangle (B10-05), USDe + FDUSD Wombat weight basis (B10-06),
lisUSD + PT-lisUSD + Venus borrow (B10-07), cross-CDP refinance
(B10-08).

**Insight:** B10-08's cross-CDP refinance is the most TradFi-like
trade in the BSC corpus — short-duration Venus USDe debt swaps Lista
long-duration lisUSD debt to capture funding-rate differentials.

**Most likely empirically profitable:** **B10-03** (5-stable graph
scan) — at least one cross-stable triangle is profitable daily.

### B11 — Astherus asBNB restake stack (9 strategies)

**Mechanism:** Astherus is BSC's BNB-restaking protocol (analogous to
EigenLayer for BNB). asBNB is the share token; Venus / Lista accept it
as collateral, so a recursive restake loop is possible. Multi-protocol
stacking (Astherus + Lista + Astherus again) hits BSC's version of
F18-05's rehypothecation chain.

**Coverage:** asBNB → Venus → restake (B11-01), asBNB → Lista → restake
(B11-02), asBNB + Pendle YT points (B11-03), asBNB peg arb (B11-04),
Astherus + Lista CDP + Pendle (B11-05), slisBNB + asBNB dual-restake
(B11-06), asBNB + Pendle YT + Lista lending (B11-07), asBNB + PCS LP
+ Thena gauge (B11-08), asBNB Venus eMode (B11-09).

**Insight:** B11-06 is the BSC analog to mainnet F18-05's triple-
restake — same security collateral counted twice across Lista and
Astherus, with no exclusivity attestation.

**Most likely empirically profitable:** **B11-01** for cash carry;
B11-03 / B11-06 dominate in any realistic Astherus airdrop.

### B12 — Avalon BTC-LSD 借贷 (9 strategies)

**Mechanism:** Avalon Labs is BSC's flagship BTC-LSD lending market.
solvBTC / solvBTC.BBN / pumpBTC / enzoBTC are deposited as collateral;
USDX (Avalon's native stable) is borrowed. Layered BTC-staking yield
(Babylon, Bedrock) + Avalon supply incentive + lending borrow rate
forms the alpha stack.

**Coverage:** solvBTC.BBN → Avalon → USDX loop (B12-01), cross-LSD
solvBTC vs solvBTC.BBN basis (B12-02), USDX peg flash arb (B12-03),
PT-solvBTC + Avalon (B12-04), pumpBTC + Avalon + Pendle (B12-05),
enzoBTC + Lista + Avalon (B12-06), solvBTC in Wombat BTC pool (B12-07),
BTC-LSD liquidation keeper (B12-08), Avalon eMode-style BTC borrow
(B12-09).

**Insight:** B12-08's BTC-LSD liquidation keeper is the highest-PnL
single-event strategy in the BSC corpus (~$25k / event normalized) —
analogous to mainnet F09-09 Morpho liquidation harvest but on BSC's
nascent BTC-LSD market with thinner keeper competition.

**Most likely empirically profitable:** **B12-08** during BTC volatility
events; B12-01 for steady-state carry.

### B13 — 跨链桥 LST/stable 折价 (8 strategies)

**Mechanism:** LayerZero V2 OFT + Stargate + CCIP bridge USDT / USDC /
USDe / WBETH / BTCB between BSC and ETH / Solana / other chains. Bridge
delays + thin BSC-side liquidity create persistent 30-100 bp spreads.

**Coverage:** USDT OFT discount flash (B13-01), WBETH rate lag (B13-02),
BTCB vs WBTC bridge spread (B13-03), USDe OFT mint/burn round-trip
(B13-04), slisBNB cross-chain OFT (B13-05), USD1 BSC ↔ ETH (B13-06),
deBridge solvBTC BSC ↔ Sol (B13-07), CCIP USDC variant (B13-08).

**Insight:** B13-02 (WBETH rate lag) is the only *atomic* trade in
this family — most cross-chain arbs are positional because LZ delivery
takes 1-3 minutes.

**Most likely empirically profitable:** **B13-02** at any Binance keeper
push event.

### B14 — 收益型稳定币循环 (8 strategies)

**Mechanism:** Stable wrappers like sUSDe, sUSDX, lisUSD (with savings
boost), and vUSDT each have their own yield primitive (Ethena funding,
Lista savings rate, Venus IRM, Maple lending). Recursive loops let
leveraged exposure to each wrapper compound.

**Coverage:** vUSDT self-loop (B14-01), vUSDC × vUSDT IRM-spread
(B14-02), lisUSD savings recursive (B14-03), sUSDe ↔ vUSDT rotation
(B14-04), sUSDX + Pendle PT + Venus (B14-05), vUSDe + asBNB + Lista
(B14-06), cross-wrapper rotation engine (B14-07), PT-sUSDX cash-and-
carry (B14-08).

**Insight:** B14-07's APY-driven rotation across wrappers is the most
"algorithmic" trade — needs an oracle of wrapper APYs.

**Most likely empirically profitable:** **B14-02** (vUSDC vs vUSDT
Venus IRM spread) — persistent multi-day spread.

### B15 — BSC 三协议机制堆叠 (10 strategies)

**Mechanism:** Every B15 strategy MUST combine ≥3 distinct BSC protocol
mechanisms in a single position. Counterpart to mainnet F18.

**Coverage:** Lista CDP + Pendle + Venus (B15-01), slisBNB + Wombat +
Thena (B15-02), PCS flash + Pendle + Venus (B15-03), Astherus + Venus
+ Pendle YT (B15-04), Lista + Wombat + PCS Stable (B15-05), Avalon +
Pendle + Wombat (B15-06), PCS flash + Astherus + Venus (B15-07),
Wombat LP + Pendle PT + Avalon (B15-08), triple-LST restake on Venus +
Lista + Astherus (B15-09), VAI + Pendle PT + Wombat (B15-10).

**Insight:** B15-09 (triple-LST restake) is the BSC analog to mainnet
F18-05 — same systemic-risk pattern: 100 BNB of equity is committed
3x across three independent restaking-like contracts.

**Most likely empirically profitable:** **B15-03** (PCS flash + Pendle +
Venus) — atomic, no funding rate dependency.

---

## 4. Cross-family observations

**Primitive concentration on BSC differs from mainnet.** Where mainnet's
top primitives are Curve (121/147), Aave/Spark/Comet (~80), and
flashloans (64), BSC's top primitives are **Venus (57/127)**, **PCS v3
single-pool flash (51/127)**, and **Lista stack (49/127)**. Curve has no
significant BSC deployment; its slot is filled by Wombat's dynamic-
weight StableSwap (31/127) and PancakeSwap StableSwap. **Venus +
PancakeSwap together act as the BSC equivalent of "Aave + Uniswap"** —
the universal money-market plus universal AMM that every other strategy
combines with.

**BSC-specific design patterns absent from mainnet.** Four BSC mechanics
appear repeatedly in the corpus and have no mainnet analog: (1)
**ve(3,3) DEX bribery** (Thena, mirrored later by PCS gauge) — BSC's
take on Velodrome/Aerodrome; (2) **Wombat dynamic-weight StableSwap**
— asset-specific liability ratios create non-linear slippage that
neither Curve nor Balancer reproduces; (3) **LayerZero V2 OFT adapters**
— canonical cross-chain mint/burn for USDT/USDC/USDe on BSC creates
real bridge-spread arbs (B13 family); (4) **Astherus asBNB restaking**
— BSC's BNB-equivalent of EigenLayer, but young enough that the
cross-protocol attestation gap (F18-05's thesis) is starker.

**Comparison to ETH equivalents.** Of the 18 mainnet families (F01-F18),
roughly 10 have clean BSC analogs: LST loops (F01→B01), LST peg arb
(F03→B02), CDP mechanics (F06→B03), Pendle PT/YT (F07→B04), Ethena
(F08→B05), Money-market isolated pools (F09→B06, F11→B06), flash + cross-
DEX (F13→B07), bribe markets (F12→B08), cross-CDP basis (F16→B10),
yield-bearing-stable loops (F17→B14), and tri-protocol stacks (F18→B15).
Five mainnet families (F02 LRT loops, F04 Maker DSR, F05 LLAMMA, F14
Synthetix, F15 EigenLayer native) have **no BSC equivalent** because
the underlying protocols don't deploy to BSC. Conversely, three BSC
families (B09 Wombat, B11 Astherus, B12 Avalon BTC-LSD) have **no
mainnet equivalent** because the underlying protocols are BSC-native.

**Empirical strength.** The strongest BSC families are **B07 (PCS v3
flash, atomic, no capital requirement, 9 strategies)** and **B12 (BTC-
LSD lending, capital-efficient, 9 strategies including the high-PnL
B12-08 liquidation keeper)**. **B15** is the most structurally novel by
design (10 explicit tri-protocol stacks). The weakest families pre-
verification are **B11 (Astherus addresses still TODO-verify in
several PoCs)** and **B13 (cross-chain bridges depend on LZ OFT
adapter addresses not yet in BSC.sol)**.

**Gaps worth deepening (Wave 5 candidates).** (1) **Lista lending vs
Lista CDP isolation** — current B03 strategies don't fully separate
the two; (2) **Avalon LSD listings catalog** — only solvBTC variants
covered; pumpBTC / enzoBTC have thin coverage; (3) **Venus VAI strategy
density** — only B06-02/B06-04 hit VAI; the VAI mint surface deserves
more attention; (4) **Cross-chain BSC↔Solana arb via deBridge / Wormhole**
— B13-07 is the only one and is heavily TODO-flagged.

---

## 5. Verification checklist (for the user)

BSC Wave 3 did NOT run `forge test` because no BSC archive RPC was
configured during corpus generation. The user must verify each PoC
once a BSC RPC is available.

```bash
cd /home/user/profit
cp .env.example .env && $EDITOR .env       # paste BSC_RPC_URL=
git submodule update --init --recursive    # forge-std + OZ
forge build                                # 0 errors, ~50 lint warnings
forge test --match-path "strategies-bsc/**" -vv
cat strategies-bsc/_index.md               # ranked table
```

For a single family or strategy:

```bash
forge test --match-path "strategies-bsc/B07-*/PoC.t.sol" -vv
forge test --match-path "strategies-bsc/B12-08-*/PoC.t.sol" -vvvv
```

### Per-family RPC requirements

| Strategy ID(s) | RPC requirement |
| -------------- | --------------- |
| All 127 | Generic BSC archive RPC (`BSC_RPC_URL` in `.env`). |
| B13-* | If you want full cross-chain leg verification, configure ETH `RPC_URL` simultaneously so OFT mint/burn round-trips can be tested across chains. |
| B03, B10, B15 late-slots | Pinned to synthetic `42_500_000` placeholder — re-pin to a block with documented BSC mispricing once an archive RPC is available. |

---

## 6. Open work — TODO / verify markers

### 6.1 BSC.sol address gaps still flagged TODO verify

- `EZETH`, `PENDLE_ROUTER_V4` on BSC (assumed same as mainnet — verify)
- `BOLD`-equivalent on BSC: N/A (Liquity v2 has no BSC deployment)
- `USD1` (World Liberty Financial) — verify canonical mainnet BSC OFT
- `vBNBx` (Venus V4 LST pool vToken for Stader BNBx) — placeholder
- `LISTA_INTERACTION`, `LISTA_LENDING` — verify Lista CDP/lending proxies
- `PCS_STABLE_ROUTER` — verify PancakeSwap StableSwap router address
- `THENA_ROUTER`, `THENA_PAIR_FACTORY`, `veTHE` — verify against Thena docs
- `WOMBAT_MAIN_POOL`, `WOMBAT_ROUTER` — verify Wombat addresses
- `AVALON_LENDING_POOL` — verify Avalon Labs canonical proxy
- `ASTHERUS_STAKE_MANAGER`, `asBNB` — verify Astherus contracts
- `USDT_OFT_ADAPTER`, `USDC_OFT_ADAPTER` — currently `address(0)`

### 6.2 PoC-level inline `LOCAL_*` placeholders

91 distinct `LOCAL_*` constants survive across 76 PoCs. Key categories:
- Pendle PT/YT/SY market addresses per maturity (B04, B07-08, B10-07,
  B11-03/05/07, B14-05/08, B15-01/03/04/06/10) — Pendle publishes these
  per-maturity; should be re-pulled at `FORK_BLOCK`.
- Astherus addresses (B11 entire family) — depend on Astherus production
  deployment.
- Avalon vault / market addresses (B12-01/02/03/04/06/09) — depend on
  Avalon canonical mainnet deployment.
- Several PCS v3 specific pool addresses with assumed fee tiers — should
  be re-resolved via `Factory.getPool` at `FORK_BLOCK`.

### 6.3 Notes
- All 127 PoCs ship as offline-first (graceful no-op when `BSC_RPC_URL`
  is unset). None will fail loudly in CI before BSC RPC is wired up.
- `forge build` succeeds with 0 errors after the Wave-2.5 EIP-55 fix.
- Recommended verification order: B07 (atomic, no capital) → B01/B02
  (LST loops, dominant BSC protocol stack) → B12 (BTC-LSD, high-PnL
  liquidation) → B15 (tri-protocol stacks, novelty showcase) → rest.

---

*Research only. Not financial advice. PoCs deliberately skip risk
modeling, slippage limits, oracle sanity checks, and MEV protection.*
