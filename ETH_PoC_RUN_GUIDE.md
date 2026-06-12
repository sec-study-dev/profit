# Ethereum PoC Suite — Porting & Run Guide

This suite contains **147 Ethereum-mainnet DeFi strategy PoCs**
(`strategies/FXX-NN-*/PoC.t.sol`). Each is a self-contained Foundry
fork-replay test: it forks mainnet at a pinned block, executes the strategy,
and prints its PnL. This document explains how to compile and run them after
copying them into another project.

---

## 1. Folders / files you need

Copy the following into the new project (keep the relative directory layout):

| Path | Required | Purpose |
|------|----------|---------|
| `strategies/`      | Yes | The 147 ETH PoCs (Foundry's test directory) |
| `src/`             | Yes | `constants/Mainnet.sol`, `Chainlink.sol`, and all `interfaces/*` |
| `test/`            | Yes | `utils/StrategyBase.t.sol` (base contract) + `PriceOracle.sol` + `Whales.sol` |
| `lib/forge-std/`   | Yes | The only external dependency |
| `foundry.toml`     | Yes | Build/test config (solc 0.8.26, via_ir, test=strategies, rpc_endpoints) |
| `remappings.txt`   | Yes | `forge-std/`, `src/`, `test/` remappings |
| `.env.example`     | Yes | Template; copy to `.env` and fill in your `RPC_URL` (see Section 3) |

**Not needed** (BSC-only or regenerable; harmless if copied anyway):
`strategies-bsc/`, `src/interfaces/bsc/`, `src/constants/BSC.sol`,
`test/utils/BSCStrategyBase.t.sol`, `test/utils/BSCWhales.sol`,
`lib/openzeppelin-contracts`, `cache/`, `out/`, `reports/`, `docs/`.

> Simplest approach: copy `strategies/ src/ test/ lib/ foundry.toml remappings.txt .env.example`
> wholesale, then create `.env` from the example.

---

## 2. Prerequisites

1. **Foundry** (forge):
   ```bash
   curl -L https://foundry.paradigm.xyz | bash && foundryup
   ```
2. **A mainnet ARCHIVE RPC** (critical): these PoCs fork at historical blocks
   (e.g. 19_700_000, 20_500_000 from 2024), which requires a node that retains
   historical state. A normal full node fails with "missing trie node /
   header not found". Use Alchemy / QuickNode / Infura (archive) / dRPC /
   paid Ankr archive, etc.
3. **solc 0.8.26**: Foundry downloads it automatically from `foundry.toml`;
   no manual install needed.

---

## 3. Create your `.env`

`.env` is intentionally **git-ignored** (it holds your RPC secret), so it is
never committed. The repo ships only the template `.env.example`. Create your
own `.env`:
```bash
cp .env.example .env
# then edit .env and replace YOUR_KEY with your mainnet archive RPC
```
`.env.example` looks like:
```
# Mainnet archive RPC. Required.
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY

# ETH/USD price used by StrategyBase for USD-denominated PnL printing.
# If unset, StrategyBase falls back to reading Chainlink ETH/USD on-fork.
ETH_USD_PRICE=
```
- **`RPC_URL`**: required; your own mainnet **archive** endpoint.
- **`ETH_USD_PRICE`**: optional; if left blank, `StrategyBase` reads Chainlink
  ETH/USD on the fork to denominate PnL.

`foundry.toml` already wires it up:
```toml
[rpc_endpoints]
mainnet = "${RPC_URL}"
```
`StrategyBase` reads `RPC_URL` via `vm.envString("RPC_URL")` to create the
fork. Load it into the shell before running:
```bash
set -a; source .env; set +a
```

---

## 4. Key foundry.toml (if merging into an existing project)

If the new project already has its own `foundry.toml`, make sure these
settings are present (otherwise compilation/run will fail):
```toml
[profile.default]
src = "src"
test = "strategies"          # ETH PoCs live under strategies/
libs = ["lib"]
solc = "0.8.26"              # required
via_ir = true                # required (some PoCs are deep; without it: "stack too deep")
optimizer = true
optimizer_runs = 200
fs_permissions = [{ access = "read", path = "./" }]

[rpc_endpoints]
mainnet = "${RPC_URL}"
```
And merge the four lines from `remappings.txt` into your remappings:
```
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
src/=src/
test/=test/
```
(`test = "strategies"` is Foundry's test-discovery directory. If your project
already has other tests, keep your own `test` path and instead select these
PoCs with `forge test --match-path "strategies/**"`.)

---

## 5. Running

First make sure `.env` is loaded (`RPC_URL` is in the environment).

**Build:**
```bash
forge build
```

**Run all 147 (serial, to avoid hammering the RPC with concurrent forks):**
```bash
forge test -vv --threads 1
```

**Run one family (e.g. F01):**
```bash
forge test --match-path "strategies/F01-*/PoC.t.sol" -vv
```

**Run a single strategy (two ways):**
```bash
# by path
forge test --match-path "strategies/F01-07-*/PoC.t.sol" -vvv
# by test function name (each PoC's function is testStrategy_FXX_NN)
forge test --match-test testStrategy_F01_07 -vvv
```

**See each PoC's PnL output**: every PoC prints via `_endPnL` at the end:
```
==== STRATEGY <label> ====
pnl_usd= ...
gas_usd= ...
net_usd= ...
```
`-vv` is enough to show these `console2.log` lines.

**With a gas report:**
```bash
forge test --match-path "strategies/F01-07-*/PoC.t.sol" --gas-report -vv
```

**Force a clean rebuild (when debugging stale-bytecode issues):**
```bash
forge clean && forge build && forge test --threads 1 -vv
```

---

## 6. Important notes (read before interpreting results)

- **`net_usd` is NOT clean realized profit.** `StrategyBase`'s PnL =
  balance delta + `_creditPositionEquity*` (which credits position equity =
  collateral − debt, and often the principal that was minted for free via
  `deal()`) + modeled carry. So large `net_usd` values mostly reflect
  **position size / credited principal**, not the size of the real edge.
  For the genuine economic edge, see each PoC's `README.md` "PnL math" section.
- **`deal()` / `vm.warp` / `vm.roll` are test devices**: PoCs use `deal()` to
  fund principal and `warp/roll` to advance time and settle carry. This is the
  standard fork-replay research method, not a real on-chain order.
- **Archive RPC is mandatory**: forking historical blocks needs historical
  state; a non-archive node will fail.
- **Run serially**: `--threads 1` avoids 147 concurrent forks rate-limiting
  your RPC.
- **via_ir must be on**: some multi-leg / flash-loan PoCs are deep; without
  via_ir you get "stack too deep".

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `vm.envString: environment variable "RPC_URL" not found` | `.env` not sourced, or `RPC_URL` not set |
| `missing trie node` / `header not found` / fork fails at a block | RPC is not an archive node — switch to archive |
| `Compilation failed: Stack too deep` | `via_ir = true` missing in `foundry.toml` |
| solc version mismatch on compile | `solc = "0.8.26"` missing in `foundry.toml` |
| Many 429s / timeouts | RPC rate-limited — add `--threads 1` or use a higher-tier RPC |
| A strategy reverts | Check that strategy's `README.md` `Block pinned` / `Preconditions`; a few are block-sensitive |

---

## 8. Directory layout
```
<project>/
├── foundry.toml
├── remappings.txt
├── .env                      # created from .env.example; RPC_URL=<mainnet archive>
├── lib/forge-std/
├── src/
│   ├── constants/            # Mainnet.sol, Chainlink.sol
│   └── interfaces/           # amm, cdp, lst, lrt, mm, pendle, stable, synth, bribe, ...
├── test/utils/               # StrategyBase.t.sol, PriceOracle.sol, Whales.sol
└── strategies/
    ├── F01-01-.../PoC.t.sol + README.md
    ├── ...
    └── F18-06-.../PoC.t.sol + README.md   # 147 total
```
