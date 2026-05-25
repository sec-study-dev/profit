# profit

Research lab for **combinations of distinctive DeFi protocol mechanisms** on
Ethereum mainnet. Each strategy is a small Foundry PoC that forks mainnet,
executes a sequence of protocol interactions, and prints a single
USD-denominated PnL/gas block for downstream aggregation.

## Purpose

We are not building production code. We are searching the design space of
*mechanism combinations* across LST / LRT / CDP / yield-bearing-stables /
Pendle / money-markets / AMMs / bribe markets / restaking, and measuring each
combination as a tiny, self-contained forked-mainnet PoC. The goal is to
surface non-obvious composites worth deeper study.

This is research only. Not financial advice. PoCs are intentionally simplified
and ignore risks, slippage tails, oracle griefing, MEV, and many other real
hazards.

## Directory layout

```
foundry.toml             Foundry config (solc 0.8.26)
remappings.txt           Import remappings
Makefile                 install / build / test / test-one / summary
.env.example             RPC_URL and price overrides
STRATEGY_IDS.md          Family ID -> Wave 2 owner table (collision contract)

src/
  constants/
    Mainnet.sol          Address book for every protocol used
    Chainlink.sol        Chainlink price-feed addresses
  interfaces/
    common/              ERC20, ERC4626, WETH, flashloan-receiver
    lst/                 Lido, RocketPool, Frax, Coinbase, Mantle, Swell
    lrt/                 EtherFi, Renzo, Kelp, Puffer
    cdp/                 Maker, crvUSD (LLAMMA), Liquity, Aave GHO
    stable/              sDAI, sUSDS, sUSDe, Ethena, USDM
    pendle/              Router/Market/PT/YT/SY
    mm/                  Morpho, Aave v3, Compound v3, Fluid, Euler, Spark
    amm/                 Curve, Balancer, Uniswap v3/v2
    bribe/               Convex, vlCVX, Votium, Hidden Hand, gauge controller
    synth/               Synthetix atomic
    restake/             EigenLayer strategy + delegation managers

test/
  utils/
    StrategyBase.t.sol   Fork helpers + USD PnL + gas accounting base class
    PriceOracle.sol      Per-token USD-price routing
    Whales.sol           Whale addresses for rebasing tokens

strategies/              Created by Wave 2; one folder per PoC (FXX-NN-name/)
```

## Setup

You need [Foundry](https://book.getfoundry.sh/). If `forge` is not on your
PATH, install foundryup first:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Then from the repo root:

```bash
make install                       # installs forge-std + openzeppelin
cp .env.example .env
$EDITOR .env                       # set RPC_URL to a mainnet archive node
make test-one ID=F01-01            # run one strategy PoC (after Wave 2)
make test                          # run all strategy PoCs
make summary                       # print aggregated results (after Wave 3)
```

## Strategy ID format

Every PoC lives at `strategies/FXX-NN-shortname/PoC.t.sol`:

- `FXX` is the **family** (see `STRATEGY_IDS.md`). One family per Wave 2 agent.
- `NN` is a zero-padded index within the family (`01`, `02`, ...).
- `shortname` is a kebab-case mnemonic.

Examples: `F01-01-steth-loop-morpho`, `F07-03-pendle-pt-leveraged`.

## Result block format

Each `_endPnL(label)` call prints a block that Wave 3 will grep:

```
==== STRATEGY <label> ====
pnl_usd=<int256, 6 decimals>
gas_usd=<uint256, 6 decimals>
net_usd=<int256, 6 decimals>
========================
```

`pnl_usd` is the realized USD change of the strategy contract's holdings
between `_startPnL()` and `_endPnL()`. `gas_usd` is `gasUsed * tx.gasprice *
ETHUSD`. `net_usd = pnl_usd - gas_usd`.

## Disclaimer

This repository is research only. Nothing here is financial advice, an
endorsement of any protocol, or a recommendation to deploy capital. PoCs are
deliberately small and skip risk modeling, slippage limits, oracle sanity
checks, and MEV protection. Do not use in production.
