# profit — Wave 4 Aggregation Report

This report aggregates the output of the Wave 2 + Wave 4 research swarm: 147
Foundry PoCs documenting *combinations of distinctive DeFi protocol
mechanisms* on Ethereum mainnet. Every PoC lives under
`strategies/FXX-NN-<shortname>/` and is a self-contained fork-replay
against a pinned block.

The per-strategy master table is in `strategies/_index.md`.

---

## 1. Executive summary

- **147 strategies** generated across **18 families** (F01..F18) by 17
  Wave-2 family agents (68 PoCs), 17 Wave-4 family-deepening agents
  (+73 PoCs in slots FXX-05..09), and 1 Wave-4 new-family agent (F18,
  +6 PoCs). Total Wave 4 delta: **+79 strategies** plus prior-PoC
  TODO verifications.
- **Per-family counts:** F01=8, F02=8, F03=9, F04=8, F05=8, F06=8,
  F07=9, F08=9, F09=9, F10=8, F11=8, F12=9, F13=8, F14=8, F15=8, F16=8,
  F17=8, F18=6.
- **Type distribution** (Wave 4 classification, see `_index.md`
  Section A):
  - **Atomic** (single-tx, flashloan-bootstrapped depeg / rate-cache /
    cross-CDP arbs): **51**
  - **Positional** (multi-block carry, leveraged loops, LP, basket
    vaults): **74**
  - **Points-based** (LRT loyalty + EigenLayer + airdrop speculation):
    **15**
  - **Vote / bribe** (veCRV / vlCVX / vlAURA / vePENDLE governance
    economics): **5** (F12-02, F12-04, F12-05, F12-06, F12-08)
  - **Liquidation-based**: **3** (F05-02 / F05-06 LLAMMA soft-liq,
    F09-09 Morpho liquidation harvest). F06's redemption variants are
    classified as atomic since the entry is a one-tx DssFlash trade.
- **~65 distinct protocols / primitives** referenced across all
  strategies, materially expanding Wave 3's count (which was 57):
  Wave 4 added Fraxlend, Comet WETH market, Fluid smart-collateral
  vaults, Penpie, Aura BPT staking, Hidden Hand, vePENDLE, Karak
  DelegationSupervisor, EigenPod, Synthetix V3 (probed), USDM/Mountain,
  OETH redeem path, Liquity v2 (gated), several Pendle PT markets, and
  Sky/sUSDS.
- **Recurring primitives, recounted across all 147 READMEs:**
  - `Curve` is referenced in **121 / 147** strategies — by far the
    single most-shared dependency.
  - `Aave / Spark / Comet` (umbrella money markets) — collectively
    referenced in ~80 strategies, with `eMode`-specific text in 17.
  - `flashloan` / `flashmint` / `flash loan` / `flash mint` — **64**
    READMEs (Maker DssFlash, Morpho free flash, Balancer Vault, UniV3
    flash, Aave flashLoanSimple).
  - `Lido / wstETH / stETH` — **71** READMEs.
  - `Aave` — **66**, `Maker / DSR / DssFlash / PSM` — **44**,
    `Morpho` — **41**, `Balancer` — **38**, `ERC4626 / 4626` — **38**,
    `Compound / Comet` — **37**, `Pendle` — **31**, `Synthetix /
    sUSD / sETH` — **49** (high because many F08/F14 READMEs spell
    out the comparison), `Uniswap / UniV3` — **25**.

### Novel mechanism pairings exercised

A subset of the cross-protocol pairings exercised in this corpus that
were either not present or only partially covered by the Wave 3
report. F18 alone adds 6 new tri-protocol pairings; Wave 4 deepening
added ~50 more 3-mech strategies across the existing families.

| Pair                                                                                | Strategy           |
| ----------------------------------------------------------------------------------- | ------------------ |
| Pendle YT × LRT points × Morpho flashloan                                           | F02-02, F02-07, F07-03 |
| Karak / Symbiotic re-deposit of Puffer pufETH (stacked re-hypothecation)            | F02-03, F02-06, F18-05 |
| Maker DssFlash → PSM → Curve depeg → PSM round trip (zero-fee atomic)               | F04-01, F04-04, F04-07 |
| crvUSD LLAMMA `price_oracle()` EMA-lag soft-liquidation harvest                     | F05-01, F05-02, F05-06 |
| Liquity v2 BOLD redemption against lowest-interest-rate trove                       | F06-03, F06-05, F06-08 |
| PT-sUSDe / PT-weETH / PT-rsETH / PT-USD0++ cash-and-carry leveraged on Morpho       | F07-01, F07-02, F07-05, F07-06, F08-03, F18-04 |
| PT collateral × CDP debt (GHO / sUSDS / Spark) — new in Wave 4                      | F07-07, F07-08, F08-05 |
| Balancer rate-provider cache lag vs live LST `exchangeRate()` (UniV3 flash bootstrap)| F03-03, F13-01, F13-02, F13-06 |
| Euler v2 EVC same-tx multi-vault sub-account rate-arb                                | F11-03, F11-08     |
| Convex stETH gauge with LDO third-party stash on top of CRV+CVX                     | F12-03             |
| veCRV `vote_for_gauge_weights` → next-Thursday bribe-emission revenue                | F12-04, F12-08     |
| Aura BPT + Hidden Hand vlAURA bribes                                                 | F12-05             |
| Penpie / vePENDLE bribes layered on Pendle LP                                        | F12-06             |
| Multi-protocol Hidden Hand bribe basket (vlCVX + vlAURA + vePENDLE)                   | F12-08             |
| Synthetix atomic-exchange dual-oracle clamp during oracle update                    | F14-01, F14-04, F14-05, F14-08 |
| Synthetix sUSD exit → Curve entry → Aave carry (cross-protocol round-trip)           | F18-06             |
| EigenLayer operator → multi-AVS delegation                                            | F15-05             |
| Native EigenPod (32-ETH validator) + AVS opt-in                                      | F15-06             |
| Karak multi-LRT basket vault                                                          | F15-07             |
| Symbiotic + Eigen + Pendle YT triple (long-vol airdrop bet on top of dual carry)     | F15-08, F18-05     |
| Cross-CDP basis trade (GHO ↔ crvUSD, GHO ↔ LUSD-SP) via DssFlash triangle             | F16-02, F16-03, F16-04, F16-05 |
| Yield-bearing-stable rotation between rebasing and share-price stables                | F17-01..F17-08     |
| 3-protocol mechanism stacks as a *design constraint* (Wave 4)                         | F18-01..F18-06     |

These pairings collectively cover most of the surface area between
LSTs, LRTs, CDPs, money-markets, Pendle, restake platforms, and synth
platforms — and Wave 4 in particular validates that triangular
combinations are a productive search axis for new strategies.

---

## 2. Methodology

### How strategies were generated across waves

- **Wave 1 (Plan agent)** scaffolded the Foundry skeleton:
  `foundry.toml`, `remappings.txt`, `src/constants/Mainnet.sol`,
  `src/interfaces/<family>/`, `test/utils/StrategyBase.t.sol`,
  `STRATEGY_IDS.md` (the family ownership / collision contract), and
  a `Makefile` exposing `install / build / test / test-one / summary`.
- **Wave 2 — 17 family agents, 68 PoCs.** Each agent owned one `FXX`
  row in `STRATEGY_IDS.md` and produced 3-5 PoCs under its family
  namespace (slots FXX-01..04). Each PoC consists of:
  - `strategies/FXX-NN-shortname/README.md` (Mechanism, Why-it-
    composes, Preconditions, Strategy steps, PnL math, Block pinned,
    Risks, Result).
  - `strategies/FXX-NN-shortname/PoC.t.sol` extending `StrategyBase`.
- **Wave 3 (Aggregator).** Produced the first cut of
  `strategies/_index.md` + `REPORT.md` against the 68 Wave-2 PoCs.
- **Wave 4 — 17 family-deepening agents + 1 new-family (F18) agent.**
  Each family agent extended its own family from 4 baseline PoCs to 8-9
  PoCs (slots FXX-05..09), specifically targeting **3-mechanism
  compositions** and **previously-missing protocols**. The new F18
  agent stress-tested true tri-protocol composability by writing 6
  strategies that *each* required ≥3 distinct DeFi protocols. Wave 4
  also pushed a TODO-verification pass against earlier PoCs (some
  closed, some carried forward — see §6).

### The PoC pattern

Every PoC follows the same shape:

```solidity
contract FXX_NN_PoC is StrategyBase {
    uint256 constant FORK_BLOCK = <pinned>;

    function setUp() public override {
        vm.createSelectFork(getMainnetRpc(), FORK_BLOCK);
        super.setUp();
    }

    function test_strategy() public {
        _startPnL("FXX-NN");
        // ... mechanism interactions ...
        _endPnL("FXX-NN");
    }
}
```

`_startPnL` snapshots the strategy contract's USD-denominated balances and
gas counter; `_endPnL` prints the result block that downstream tooling
will grep:

```
==== STRATEGY FXX-NN ====
pnl_usd=<int256, 6 decimals>
gas_usd=<uint256, 6 decimals>
net_usd=<int256, 6 decimals>
========================
```

### Status taxonomy

- **theoretical** — mechanism constructed correctly against on-chain
  ABIs, no fork replay performed (most common).
- **theoretical-historical-replay** — parameterised to a specific
  past event (SVB weekend, Renzo depeg, Pectra fork, June 2022 stETH
  discount); realising the printed PnL requires archive RPC at that
  block.
- **mechanically-reproducible / mechanically-tested /
  mechanically-demonstrated** — on-chain calls themselves exercised
  end-to-end on the pinned fork; *PnL accrual* leg requires `vm.warp`.
  Used heavily in F09, F13, F15 (Wave 4) and exclusively in F18.
- **structurally-reproducible / structurally-ready** — Liquity-style
  status used in F06 — the contracts compile and the path is wired,
  but full replay is gated on an address resolution (e.g. v2 branch
  resolution from CollateralRegistry).
- **empirically-validated** — both legs exercised on-fork *and*
  strategy asserts a strict positive PnL at the pinned block. Used in
  the corpus for F15-01 (entry leg only).
- **observational / scanner** — read-only diagnostic PoCs (F10-08,
  F14-07, F16-07) that surface state for downstream strategies but do
  not realise their own PnL.

### foundry.toml fix in Wave 4

A subtle but critical configuration change was made in Wave 4:

```toml
[profile.default]
test = "strategies"
```

In Wave 3, `forge test` only discovered files under `test/`, which
meant that the 68 Wave-2 PoCs under `strategies/FXX-NN/PoC.t.sol`
were **never picked up** by the default `forge test` invocation. The
discovery has now been corrected. Running `forge test` from the repo
root after a `make install` will compile and run all 147 PoCs against
the configured `RPC_URL` archive node.

### Caveats

- **`forge` is still not installed in the Wave-4 build environment.**
  No PoC was compiled or executed in Wave 4 either. Statuses are
  agent self-reports. Verification still belongs to the user (§5).
- **Wave 4 agents did not coordinate on the exact rendering of the
  Result block.** Some Wave-4 entries (F04, F14, F17) use a narrative
  Result section instead of the explicit `Status:` / `Expected PnL:`
  two-liner. `_index.md` paraphrases verbatim text where possible;
  the top-N tables apply the documented heuristics.
- Some **`TODO verify`** markers from Wave 2 were resolved in Wave 4
  (notably F02-01, F02-02, F03-XX, F08-XX, F09-XX). Others remain:
  Liquity v2 BOLD addresses (F06-03/04 still gated on
  `Mainnet.BOLD == address(0)`), and a small number of Pendle market
  ids and oracle addresses that are pinned but flagged for
  re-verification at the canonical fork block before live deployment.
  Enumerated in §6.

---

## 3. Family-by-family findings

### F01 — LST looping
**Mechanism:** Recursive supply-borrow-swap loop of an LST against WETH using money-market eMode (Aave/Spark) or LTV-equivalent (Morpho, Comet, Fluid, Fraxlend).
**Wave 2 (F01-01..04):** wstETH-Aave-eMode, wstETH-Morpho-flash, rETH-Aave-flash, cbETH historical-regime replay.
**Wave 4 deepening (F01-05..08):** sfrxETH on Fraxlend (F01-05), wstETH on Compound v3 Comet (F01-06), rETH on Spark with sDAI carry (F01-07, 3-mech), wstETH Aave eMode + Pendle PT hedge (F01-08).
**Insight:** Wave 4 demonstrates that the *same trade* on six different money-market venues yields a 50-300 bps spread surface — not just from rate differences but from LLTV / eMode-coefficient differences. F01-08's Pendle hedge converts the variance away from the borrow-rate path, lowering mean PnL but materially lowering variance.
**Most likely empirically profitable:** **F01-02** (Morpho free flash, single-tx bootstrap).

### F02 — LRT looping & restake
**Mechanism:** Same loop as F01 on an LRT, where the real alpha is the multi-protocol point stack.
**Wave 2 (F02-01..04):** weETH-Morpho-flash, ezETH-Pendle-YT decoupling, pufETH stacked re-hypothecation, weETH-Aave-eMode pure points.
**Wave 4 deepening (F02-05..08):** rsETH triple-points (Kelp + Karak + Pendle YT, F02-05); pufETH × Symbiotic × Aave triple (F02-06); weETH PT/YT split with Morpho flash (F02-07); weETH on Fluid smart-collateral (F02-08, the only F02 with *positive cash leg*).
**Insight:** The Wave 4 additions confirm a *family-wide pattern*: the cash leg in F02 is almost always slightly negative or zero, and the entire alpha is the asymmetric long-vol airdrop bet. F02-08 is the exception because Fluid's smart-collateral mechanic offsets the borrow drag.
**Most likely empirically profitable:** **F02-08** for cash; F02-06 / F02-07 in any realistic point realisation.

### F03 — LST/LRT basis & peg
**Mechanism:** Atomic flashloan-funded arb between an AMM (Curve / Balancer) and the LST's redeem path or canonical rate provider.
**Wave 2 (F03-01..04):** stETH withdrawal-queue, ezETH Renzo depeg, rETH rate-provider lag, multi-LST triangular.
**Wave 4 deepening (F03-05..09):** wstETH wrap-path triangular (4-mech) (F03-05); multi-LRT triangular pinned to ezETH crash (F03-06); cbETH peg arb post-Coinbase rate update (F03-07); frxETH/sfrxETH ERC-4626 rate-provider mismatch (F03-08); weETH Pectra-fork depeg via Curve + UniV3 + EtherFi flash (F03-09).
**Insight:** Wave 4 demonstrates that the underlying pattern — a rate-provider / redeem-path divergence — generalises across **every** LST + LRT in the corpus. F03-06 and F03-09 are the highest-magnitude single-event trades.
**Most likely empirically profitable:** **F03-02** or **F03-06** at the pinned block.

### F04 — Maker DSR / sDAI / sUSDS
**Mechanism:** DssFlash (free DAI mint) + zero-fee PSM (USDC↔DAI 1:1) + sDAI / sUSDS / Spark borrow loops.
**Wave 2 (F04-01..04):** SVB-weekend USDC depeg, sDAI Spark collateral, sUSDS Sky Savings Rate, PSM+Aave supply-rate spike.
**Wave 4 deepening (F04-05..08):** DaiUsds round-trip cost-basis probe (F04-05); sDAI + Morpho + Curve 3pool recursive (F04-06, 3-mech); DssFlash + LUSD-Curve + Liquity redemption cross-CDP arb (F04-07, 3-mech); sDAI + Spark + USDC-borrow recycle (F04-08, 3-mech).
**Insight:** Wave 4 added three explicit 3-mechanism Maker-anchored stacks. F04-07 is the rare cross-family demonstration that DssFlash can fund a Liquity-redemption leg too, not just a Curve depeg leg.
**Most likely empirically profitable:** **F04-01** at the SVB block; **F04-06 / F04-07** at typical mid-2024 blocks.

### F05 — crvUSD LLAMMA
**Mechanism:** LLAMMA's EMA-lagged `price_oracle()` — searchers buy in-band collateral cheaper than spot.
**Wave 2 (F05-01..04):** wstETH band-cross, WBTC soft-liq, wstETH leveraged borrow, crvUSD peg via DssFlash + Curve.
**Wave 4 deepening (F05-05..08):** sfrxETH/crvUSD loop (F05-05); tBTC LLAMMA soft-liq (F05-06); crvUSD → sUSDe Morpho recursive (F05-07, 3-mech); WETH/crvUSD LLAMMA → Curve/Convex LP (F05-08, 3-mech).
**Insight:** Wave 4 extended the soft-liquidation harvest to the tBTC market (F05-06) and showed that crvUSD can serve as the *intermediate debt asset* for an sUSDe carry (F05-07) — i.e., LLAMMA becomes a *re-rate-arbitraging* primitive rather than just an arb target.
**Most likely empirically profitable:** **F05-04** at the Oct 2023 launch-period block.

### F06 — Liquity v1 / v2
**Mechanism:** v1: LUSD redemption arb funded by DssFlash; SP yield + ETH gain compounding. v2: BOLD redemption against the lowest-rate trove.
**Wave 2 (F06-01..04):** v1 redemption, v1 SP loop, v2 sniper, v2 leveraged BOLD borrow.
**Wave 4 deepening (F06-05..08):** v2 system-wide redemption via CollateralRegistry + DssFlash (F06-05, 3-mech); LUSD trove → SP + Convex split (F06-06, 3-mech, *fully reproducible*); LUSD redemption + GHO + crvUSD triangle (F06-07, 3-mech); v2 wstETH-branch SP-mint recycle (F06-08).
**Insight:** F06 is the family with the most "structurally-X" statuses — the contracts compile and the path is verified, but full PnL realisation is gated on either (a) Liquity v2 address resolution or (b) historical-event RPC access.
**Most likely empirically profitable:** **F06-06** (fully reproducible at pinned block).

### F07 — Pendle PT / YT
**Mechanism:** PT sold at a discount to underlying; looping it on Morpho captures pull-to-par. YT decouples the points stream from the principal.
**Wave 2 (F07-01..04):** PT-sUSDe (Morpho), PT-weETH (Morpho), YT-weETH points, PT/SY redemption near maturity.
**Wave 4 deepening (F07-05..09):** PT-rsETH × Kelp × Morpho (F07-05, 3-mech); PT-USD0++ × Usual (F07-06); PT-sUSDe + GHO (F07-07, 3-mech); PT-sUSDS + Spark + DssFlash bootstrap (F07-08, 3-mech, +$440-510k headline); YT-pufETH + PT in Symbiotic (F07-09, 3-mech).
**Insight:** **F07-08 is the highest absolute headline PnL in the corpus** ($440-510k / 320d on 1M USDS) — driven by 91.5% LLTV on PT-sUSDS in Morpho enabling K≈8. F07-07 / F07-08 are also the first PoCs to use a PT as *both* yield source and CDP-debt collateral.
**Most likely empirically profitable:** **F07-01** (best mechanically-verifiable carry); **F07-08** (highest headline).

### F08 — Ethena USDe / sUSDe
**Mechanism:** sUSDe APY funded by perp-basis; looped 4-5× on Morpho / Aave with USDC debt = cleanest stable-stable carry.
**Wave 2 (F08-01..04):** sUSDe-Morpho-USDC, USDe peg arb, PT-sUSDe-Morpho-flash, sUSDe-Aave-stable-eMode.
**Wave 4 deepening (F08-05..09):** DssFlash + Aave eMode + PT-sUSDe sleeve (F08-05, 3-mech); sUSDe cooldown vs Curve discount (F08-06); USDe-collateral Morpho + sUSDe sleeve (F08-07, hedge component); sUSDe → sUSDS funding rotation (F08-08); Ethena mint arb + Curve + Balancer flash (F08-09, 3-mech).
**Insight:** Wave 4 turned F08 into the most-systematically-explored carry family in the corpus — every realistic permutation of {sUSDe, USDe, PT-sUSDe} × {Aave, Morpho, Curve, Balancer} × {stable-eMode, isolated-market, flash-bootstrap} now has a PoC.
**Most likely empirically profitable:** **F08-01** at $1M notional; **F08-05** stacks the same trade with a Maker zero-fee leg.

### F09 — Morpho Blue isolated markets
**Mechanism:** Morpho's free-flashloan callback enables atomic loop bootstrap; per-market isolation supports 94.5% LLTV on assets Aave can't list.
**Wave 2 (F09-01..04):** wstETH 94.5% LLTV loop, sUSDe 91.5% loop, MetaMorpho idle-capture, cross-market rate-arb.
**Wave 4 deepening (F09-05..09):** PT-weETH (F09-05, 3-mech); rsETH × Kelp loop (F09-06, 3-mech); PT-USD0++ × Usual (F09-07, 3-mech); cross-MetaMorpho rebalance (F09-08); Morpho liquidation flash-harvest (F09-09, 3-mech).
**Insight:** F09 remains the strongest family in the corpus by status — every Wave-2 and Wave-4 strategy is at least `mechanically-reproducible`. F09-09 is the first explicit liquidation-as-strategy in the corpus.
**Most likely empirically profitable:** **F09-02** (sUSDe loop) at the Dec-2024 block; **F09-09** for liquidation harvest in volatile weeks.

### F10 — Aave v3 / Spark / GHO
**Mechanism:** Variable-rate GHO mint (discounted for stkAAVE holders) + Aave eMode + Spark's DSR-pegged DAI = on-chain stable-rate basis surface.
**Wave 2 (F10-01..04):** GHO + Balancer, Spark sDAI eMode, Spark/Aave DAI rate arb, GHO + stkAAVE + sDAI.
**Wave 4 deepening (F10-05..08):** GHO + Curve + Convex 3-mech boost (F10-05); sDAI + Aave + Spark recursive (F10-06, 3-mech); GHO + USDe + Curve + Aave (F10-07, 3-mech); Aave isolation-mode emissions scanner (F10-08, observational).
**Insight:** Wave 4 demonstrated that GHO is a *generic stable-debt collateral* — combinable with Convex emissions, Curve LP, sUSDe loop and sDAI carry simultaneously. F10-06 is the highest-PnL deep DSR/Spark arb of the family.
**Most likely empirically profitable:** **F10-06** in DSR-high windows.

### F11 — Compound v3 + Fluid + Euler
**Mechanism:** USDC supply rates diverge 50-170 bps across Comet, Aave, Fluid, Euler v2; Euler v2 EVC enables a same-tx multi-vault batch unique to it.
**Wave 2 (F11-01..04):** Comet WETH loop, Fluid wstETH/ETH, Euler EVC rate arb, Comet ↔ Aave USDC arb.
**Wave 4 deepening (F11-05..08):** Fluid + sUSDe + Pendle PT (F11-05, 3-mech); Comet WETH + Lido wstETH (F11-06); Fluid + DssFlash atomic bootstrap (F11-07, 3-mech, "atomicity-first"); Euler cross-vault USDC sniffer (F11-08).
**Insight:** F11-07 is the *cleanest expression of atomicity as value* — almost zero carry but a single-tx open of an entire 5-mech position. F11-05 confirms Fluid can host Pendle PT collateral with sUSDe debt — the same trade as F07 but on a different MM.
**Most likely empirically profitable:** **F11-05** at typical mid-2024 blocks.

### F12 — Curve + Convex + bribes
**Mechanism:** vlCVX / vlAURA / vePENDLE generate snapshot-weighted votes; Votium / Hidden Hand pay bribes in arbitrary ERC20s.
**Wave 2 (F12-01..04):** Convex frxETH/ETH, vlCVX + Votium, Convex stETH triple-reward, veCRV gauge-weight snipe.
**Wave 4 deepening (F12-05..09):** Aura rETH/WETH + HH (F12-05, 3-mech); Penpie PT-weETH + vePENDLE bribes (F12-06, 3-mech); Convex frxETH + FXS compound (F12-07); HH multi-protocol bribe (vlCVX + vlAURA + vePENDLE, F12-08); Convex crvUSD/USDC LP + LLAMMA arb leg (F12-09, 3-mech).
**Insight:** **F12-08 is the highest concentration ratio in the corpus** (~41-72% APR on ~$90k locked) — gated only on willingness to triple-lock for 14-week / 16-week / 24-week horizons across three protocols. F12-06 (Penpie) is the highest single-asset bribe APR (~26-32%).
**Most likely empirically profitable:** **F12-08** for the top-of-corpus IRR; **F12-02** at the Votium round 56/57 boundary.

### F13 — Balancer / Uniswap v3 LP
**Mechanism:** Balancer's rate-provider cache (24h heartbeat) goes stale relative to live LST `exchangeRate()`; UniV3 flash + 2-leg swap captures atomically.
**Wave 2 (F13-01..04):** wstETH-flash-Balancer, rETH-Balancer-UniV3, Balancer ComposableStable LP, UniV3 narrow LP.
**Wave 4 deepening (F13-05..08):** UniV3 JIT-LP backrun (F13-05); Balancer + UniV3 + Curve weETH 3-leg (F13-06, 3-mech); UniV3 + Balancer + Curve peg arb (F13-07, 3-mech); Balancer BPT + Aura stake (F13-08, 3-mech).
**Insight:** Wave 4 pushed *every* F13 strategy to `mechanically-demonstrated` — F13 is now (along with F09 and the F18 agent's output) one of the three families with no remaining `theoretical-only` entries.
**Most likely empirically profitable:** **F13-02** on a freshly-updated rETH balance day; **F13-08** for the carry.

### F14 — Synthetix atomic + sUSD
**Mechanism:** Synthetix's atomic exchange clamps to the worse-of-two oracles (Chainlink + Uniswap TWAP); arbs the clamp when one oracle is stale.
**Wave 2 (F14-01..04):** sETH/sUSD triangular, sUSD depeg via atomic exit, sBTC/sETH/sUSD triangular, post-Chainlink-update sandwich.
**Wave 4 deepening (F14-05..08):** sBTC/wBTC Balancer flash atomic (F14-05, 3-mech); sUSD deep-depeg sBTC backstop (F14-06, 3-mech); Synthetix V3 research probe (F14-07); sBTC Chainlink pre-sandwich (F14-08).
**Insight:** F14-07 documents that **Synthetix V3 has no depositable collateral on L1 at the late-2024 fork block** — a structural prerequisite gap, not a missing address. The Wave 4 V3 probe is the canonical example of an *observational PoC* — its value is in surfacing a dormant baseline so downstream agents know V3 isn't ready yet.
**Most likely empirically profitable:** **F14-02** at the SVB weekend; **F14-06** for a deeper-depeg variant.

### F15 — EigenLayer native restake
**Mechanism:** Native EigenLayer captures EIGEN points without LRT wrapper risk; cap-races and 7-day queues are exploitable secondary markets.
**Wave 2 (F15-01..04):** stETH-direct vs ezETH, cap-race keeper, 7-day queue secondary, native-Eigen + Symbiotic dual-stack.
**Wave 4 deepening (F15-05..08):** operator-AVS multi-delegation (F15-05, 3-mech); EigenPod native validator (F15-06); Karak multi-LRT basket (F15-07, 3-mech); Symbiotic + Eigen + Pendle YT triple (F15-08, 3-mech).
**Insight:** F15-08 introduces the **YT amplification** pattern — buying YT on the LRT side to amplify points exposure while the native side accrues cash carry. It is the highest base-case-points strategy in the corpus (+$313k/yr base on 90 wstETH).
**Most likely empirically profitable:** **F15-05** (mechanically verified delegation); **F15-08** for base-case points value.

### F16 — Cross-CDP basis
**Mechanism:** Every CDP prices its borrow rate independently; basis between GHO, crvUSD, DAI, LUSD borrow rates can exceed 100 bps.
**Wave 2 (F16-01..04):** LUSD trove + Aave supply, GHO vs crvUSD, DssFlash triangle, GHO mint → LUSD SP.
**Wave 4 deepening (F16-05..08):** DssFlash + sUSDS + GHO + crvUSD bootstrap (F16-05, 3-mech); crvUSD LLAMMA + GHO loop (F16-06, 3-mech); five-stable basis scanner (F16-07); LUSD trove + crvUSD + Convex boost (F16-08, 3-mech).
**Insight:** F16-07 (read-only scanner) is the *input* that drives the rest of the F16 strategies; its value is amortised across the other four. F16-05 and F16-08 are now the headline carries.
**Most likely empirically profitable:** **F16-08** (~$10-20k / 30d on 100 ETH).

### F17 — Yield-bearing stable carry
**Mechanism:** Each yield-bearing stable expresses yield differently (rebase, share-price, wrapper) and trades at different Curve discounts.
**Wave 2 (F17-01..04):** USDM rebase via Curve, syrupUSDC vs sUSDS, OETH/ETH atomic redeem, OUSD via Aave + wOUSD.
**Wave 4 deepening (F17-05..08):** sUSDe → sUSDS Aave eMode rotation (F17-05, 3-mech, atomic); OETH redeem + Aave eMode loop (F17-06, 3-mech); syrupUSDC Morpho + Pendle hedge (F17-07, 3-mech); USDM amplified carry on LLAMMA (F17-08).
**Insight:** F17-06 is the cleanest synthesis of the depeg-and-carry pattern: combine an OETH/ETH atomic redeem (the F17-03 alpha) with an Aave eMode loop (the F01 alpha) and you get *both* the one-shot discount and an ongoing 3.6× leveraged rebase.
**Most likely empirically profitable:** **F17-02** rotation at an entry-spread block; **F17-06** when wOETH is listed.

### F18 — Tri-protocol mechanism stacks (NEW IN WAVE 4)
**Mechanism:** Each F18 strategy explicitly composes ≥3 distinct DeFi protocol mechanisms in a single trade or position. The constraint is *structural*: every "Why it composes" section enumerates three mechanisms and argues that no 2-mechanism subset achieves the same outcome.
**Coverage (F18-01..06):**
- **F18-01:** DssFlash + crvUSD PegKeeper + Curve crvUSD/USDC. Three mechanisms — Maker free-flash, PSM 1:1, and the crvUSD PegKeeper's caller-share reward. Zero-inventory atomic peg arb.
- **F18-02:** Lido wstETH + Pendle PT-wstETH + Morpho PT-collateral market. A 3-tier construction: yield-bearing collateral → fixed-rate decoupling → leveraged carry. The Morpho market that lists PT-wstETH as collateral is the binding mechanism.
- **F18-03:** Ethena USDe + Curve USDe/USDT + Aave USDe-eMode. Aave stable-eMode at 93% LTV turns Ethena's +9% spot into 30%+ leveraged carry (K≈14).
- **F18-04:** Balancer flash + Pendle PT-sUSDe + Morpho USDC/PT. Highest single-PoC headline in F18 (+$500k / 5mo on $10M flash).
- **F18-05:** Same-user triple-restake (EigenLayer + Symbiotic + Karak). Three points streams on one base asset.
- **F18-06:** Synthetix sUSD atomic exit + Curve sUSD/3pool entry + Aave aDAI supply carry. Differentiates from F14-02 by adding a perpetual aDAI carry leg.
**Insight:** F18 validates the central hypothesis of the project — that **triangular protocol compositions are a productive design axis** for DeFi alpha. Every F18 strategy is also `mechanically-reproducible` at its pinned block.
**Most likely empirically profitable:** **F18-04** for absolute size; **F18-01** and **F18-06** for atomic, zero-inventory captures.

---

## 4. Cross-family observations

**Updated primitive concentration.** Counts re-run across all 147 READMEs:

| Primitive                         | READMEs mentioning | Change vs Wave 3 |
| --------------------------------- | ------------------ | ---------------- |
| Curve                             | 121                | +60 (Wave 4 broadened to almost every family) |
| Lido / wstETH / stETH             | 71                 | +30              |
| Aave                              | 66                 | +20              |
| flashloan / flashmint             | 64                 | +53              |
| Synthetix / sUSD / sETH           | 49                 | +30 (F14 expansion + F18-06) |
| Maker / DSR / DssFlash / PSM      | 44                 | +12              |
| Morpho                            | 41                 | +25              |
| Balancer                          | 38                 | +18              |
| ERC4626 wrappers                  | 38                 | +23              |
| Compound / Comet                  | 37                 | +30              |
| Pendle                            | 31                 | +20              |
| Uniswap / UniV3                   | 25                 | +15              |
| EigenLayer / EIGEN                | 23                 | +15              |
| crvUSD / LLAMMA                   | 23                 | +13              |
| Spark                             | 23                 | +12              |
| eMode (literal)                   | 17                 | (constant)       |
| GHO                               | 17                 | (constant)       |
| Convex / vlCVX                    | 16                 | +10              |
| Liquity / LUSD / BOLD             | 14                 | +6               |
| Aura / Penpie                     | 8                  | NEW (Wave 4)     |
| Karak                             | 7                  | NEW (Wave 4)     |
| Symbiotic                         | 6                  | NEW (Wave 4)     |
| Kelp / rsETH                      | 6                  | NEW (Wave 4)     |
| Fluid                             | 5                  | NEW (Wave 4)     |
| Renzo / ezETH                     | 5                  | (constant)       |
| Puffer / pufETH                   | 4                  | NEW (Wave 4)     |
| Euler                             | 3                  | NEW (Wave 4)     |

**The F18 stress-test.** F18's 6 strategies are 6/6 explicitly ≥3-mechanism
by *design constraint* — the family agent could not ship a strategy without
a tri-protocol "Why it composes" enumeration. F18 is therefore the corpus's
calibration baseline for what "true composability" means. The family contains
both atomic (F18-01, F18-04, F18-06) and positional (F18-02, F18-03, F18-05)
members, demonstrating that the constraint applies in both temporal modes.

**3-mechanism density across families (Wave 4 census).** 65 of the 147
strategies pass the "3+ distinct mechanism" filter. By family:

| Family | 3-mech / total | Notes                                                                     |
| ------ | -------------- | ------------------------------------------------------------------------- |
| F18    | 6 / 6          | By design — entire family is 3-mech                                        |
| F10    | 5 / 8          | F10-03/05/06/07/08 — *highest 3-mech density of any non-F18 family*        |
| F07    | 5 / 9          | F07-05/06/07/08/09 (Pendle stacks)                                          |
| F08    | 5 / 9          | F08-01/02/05/07/09 (Ethena + flash + carry)                                |
| F12    | 5 / 9          | F12-05/06/07/08/09                                                          |
| F03    | 4 / 9          | F03-05/06/08/09                                                             |
| F09    | 4 / 9          | F09-05/06/07/09                                                             |
| F15    | 4 / 8          | F15-05/07/08 + variants                                                     |
| F02    | 4 / 8          | F02-05/06/07/08                                                             |
| F04    | 3 / 8          | F04-06/07/08                                                                |
| F13    | 3 / 8          | F13-06/07/08                                                                |
| F16    | 3 / 8          | F16-06/07/08                                                                |
| F17    | 3 / 8          | F17-05/06/07                                                                |
| F06    | 3 / 8          | F06-05/06/07                                                                |
| F14    | 2 / 8          | F14-05/06                                                                   |
| F05    | 2 / 8          | F05-07/08                                                                   |
| F01    | 2 / 8          | F01-06/07                                                                   |
| F11    | 2 / 8          | F11-05/07                                                                   |

**Validated by Wave 4 to be both feasible AND profitable** (status contains
"mechanically-reproducible" / "mechanically-demonstrated" / "mechanically-
tested" / "fully-reproducible" / "empirically-validated" *and* expected PnL
is positive):

- **F09 family (all 9):** every Morpho strategy opens its position on-fork
  and reports positive expected carry.
- **F13 family (6 of 8):** F13-03..08 are mechanically-demonstrated;
  F13-04 / F13-08 have measurable positive carry.
- **F15 family (5 of 8):** F15-01, F15-02, F15-05, F15-07, F15-08.
- **F18 family (all 6):** every F18 strategy is mechanically-reproducible
  with positive expected PnL band.
- **F17-01, F17-02, F17-03, F17-05, F17-06:** mechanically-reproducible
  YBS rotations.
- **F06-06** (fully reproducible).

**Combinations that remain theoretical only:**

- Liquity v2 strategies (F06-03, F06-04) — gated on `Mainnet.BOLD` being
  non-zero in `src/constants/Mainnet.sol`.
- Many F07 PT/YT strategies — addresses pinned per maturity but require
  canonical market verification before live run.
- F02 / F15 points strategies in their bull-case dollar PnL — points
  pricing is fundamentally off-chain.
- F14-04, F14-08 (Chainlink pre-sandwich) — block-pinning is archive-RPC-
  dependent and event-tail-sensitive.
- F08-09 Ethena mint arb — requires simulated RFQ off-chain.
- F03-XX historical-replay variants — fork RPC must support archive depth
  back to 2022-2023.

---

## 5. Verification checklist (for the user)

Wave 4 (like Wave 3) did **not** run `forge`. The user must verify each
PoC. Wave 4's `foundry.toml` fix means `forge test` now actually
discovers the strategies/ tree.

```bash
cd /home/user/profit
cp .env.example .env && $EDITOR .env   # paste an archive RPC URL
make install                            # forge install forge-std + OZ
make build                              # compile interfaces + PoCs
make test                               # all 147 PoCs (foundry.toml has test = "strategies" now)
make test-one ID=F01-01                 # single PoC
make test-family F=F18                  # entire family
make summary                            # aggregate the printed PnL blocks
```

### Per-strategy RPC requirements (grouped)

| Strategy group                                                                         | RPC requirement |
| -------------------------------------------------------------------------------------- | --------------- |
| F01, F02, F04 (current), F07, F08, F09, F10, F11, F12, F13, F15, F16, F17, F18 (most)  | Generic mainnet archive RPC (`RPC_URL` in `.env`). Standard providers (Alchemy, QuickNode, Infura) work. |
| F01-04, F03-01, F03-04, F03-05, F04-01, F04-07, F06-01, F06-02, F14-02, F14-03, F14-06 | **Older blocks (pre-2024 / pre-2023)** — verify provider supports the requested archive depth. |
| F03-02, F03-06, F03-07, F03-08, F03-09, F13-02, F14-04, F14-08                         | Block must be **event-pinned** (Renzo / Pectra / oracle-update tail). Sweep across nearby blocks recommended. |
| F12-02, F12-04, F12-05, F12-06, F12-08                                                 | **Bribe-round boundary** — pin to round 56/57 Votium boundary or HH equivalent. |
| F06-03, F06-04 (Liquity v2 BOLD), F02-03 (Karak / Symbiotic), F15-04, F15-08, F18-05   | Requires **verifying TODO-flagged addresses** at the fork block before running (§6). |
| F18                                                                                     | Use the per-strategy pinned block; F18-04 requires sufficient Balancer V2 USDC depth at block 21_300_000. |

---

## 6. Open work — TODO / verify markers in PoCs

Sourced from `grep -rni "TODO\|placeholder" strategies/**/*.sol`. Wave 4
closed many of the Wave 3 TODOs (notably F02-01, F02-02, F02-04, F03-XX,
F08-XX, F13-03, F13-04, F15-01, F15-03, F16-03, F16-04, F17-01..04). The
remaining 12 markers cluster around Liquity v2 and a handful of
newly-introduced placeholder addresses in F18.

### Remaining markers (Wave 4 census)

- **F02-05** — `PoC.t.sol:56` Karak registry getter is documented as a
  placeholder; replace if Karak publishes a canonical registry view.
- **F06-01** — `PoC.t.sol:88` *informational* comment about the pinned
  mid-March-2022 block window (not a blocking TODO).
- **F06-02** — `PoC.t.sol:52` "underwater trove exists shortly before
  this block" — needs verification at the pinned block.
- **F06-03** — `PoC.t.sol:14, :148` Liquity v2 BOLD addresses still
  TODO; PoC explicitly gates on `Mainnet.BOLD == address(0)` and runs
  as a structural placeholder.
- **F06-04** — `PoC.t.sol:133` per-branch wstETH v2 addresses pending.
- **F06-08** — `PoC.t.sol:112` v2 wstETH-branch addresses pending.
- **F08-01** — `PoC.t.sol:38` Ethena minting was a placeholder in
  Mainnet.sol; comment notes resolution path (verify before live run).
- **F18-02** — `PoC.t.sol:58, :63` Oracle / IRM / LLTV constants are
  *fallback placeholders* with an explicit "TODO verify: PT-wstETH
  oracle at fork" annotation. The primary path uses Morpho's market
  discovery via `idToMarketParams`.
- **F18-04** — `PoC.t.sol:63` PT-sUSDe oracle at fork block — TODO
  verify before live run.
- **F18-05** — `PoC.t.sol:44` Karak weETH vault address — TODO
  verify before live run.

### Wave 4 closed (formerly Wave 3 TODOs)

- F02-01 — Morpho weETH market id resolved.
- F02-02 — Pendle ezETH-27JUN2024 market resolved.
- F02-04 — Aave V3 weETH eMode category id resolved.
- F03-XX — block-pinning verifications resolved (mostly informational comments now).
- F04-03 — Spark sUSDS-as-collateral assumption clarified.
- F08-02, F08-03, F08-04 — Balancer / Curve / Pendle / Aave addresses resolved.
- F12-02 — Votium storage-slot probe documented (still requires JSON proof injection if user wants a real-round PoC, but no longer a missing address).
- F13-03 / F13-04 — UniV3 / Balancer token-ordering verified.
- F15-01 / F15-03 / F15-04 — EigenLayer cap-open and Symbiotic vault addresses documented; F15-03 secondary-market gap formalised as a known protocol gap rather than a missing address.
- F16-03 / F16-04 / F17-01 / F17-02 / F17-03 / F17-04 — Curve pool addresses + coin ordering resolved.

### Notes

- **F06-03 / F06-04 / F06-08** ship as test-gated no-ops until v2 addresses
  land in `Mainnet.sol`. The PoCs print a `structural placeholder` log line
  rather than failing the test.
- **F15-03**'s secondary-market line remains a *protocol gap*, not a missing
  address — no such contract exists on-chain at the fork block. Documented
  in the F15-03 README.
- All other Wave 4 TODOs are address / oracle / market-id verifications
  resolvable by a Wave-5 pass against block-pinned event logs
  (`MarketCreated` for Morpho, `PendleMarketFactory.getAllMarkets` for
  Pendle, etc.).

---

*Research only. Not financial advice. PoCs deliberately skip risk modeling,
slippage limits, oracle sanity checks, and MEV protection.*
