# Ethereum PoC 套件 — 移植与运行指南

本套件包含 **147 条以太坊主网 DeFi 策略 PoC**（`strategies/FXX-NN-*/PoC.t.sol`），
每条都是一个自包含的 Foundry fork-replay 测试：在某个固定主网区块上 fork，执行
策略并打印 PnL。本文说明把它们移到另一个项目后如何编译与运行。

---

## 1. 需要的文件夹 / 文件

复制以下内容到新项目（保持相对目录结构不变）：

| 路径 | 必需 | 作用 |
|------|------|------|
| `strategies/` | ✅ | 147 条 ETH PoC（Foundry 的 test 目录） |
| `src/`        | ✅ | `constants/Mainnet.sol`、`Chainlink.sol` 及全部 `interfaces/*` |
| `test/`       | ✅ | `utils/StrategyBase.t.sol`（基类）+ `PriceOracle.sol` + `Whales.sol` |
| `lib/forge-std/` | ✅ | 唯一外部依赖 |
| `foundry.toml`   | ✅ | 编译/测试配置（solc 0.8.26、via_ir、test=strategies、rpc_endpoints） |
| `remappings.txt` | ✅ | `forge-std/`、`src/`、`test/` 重映射 |
| `.env`           | ✅ | 设置 `RPC_URL`（主网 archive RPC） |

**不需要**（BSC 专用或可重建，复制了也无害）：
`strategies-bsc/`、`src/interfaces/bsc/`、`src/constants/BSC.sol`、
`test/utils/BSCStrategyBase.t.sol`、`test/utils/BSCWhales.sol`、
`lib/openzeppelin-contracts`、`cache/`、`out/`、`reports/`、`docs/`。

> 最省事做法：整体复制 `strategies/ src/ test/ lib/ foundry.toml remappings.txt .env`。

---

## 2. 前置条件

1. **Foundry**（forge）：
   ```bash
   curl -L https://foundry.paradigm.xyz | bash && foundryup
   ```
2. **主网 archive RPC**（关键）：这些 PoC fork 在历史区块（如 19_700_000、
   20_500_000 等 2024 年的块），必须用**能读历史 state 的 archive 节点**。普通
   全节点会报 "missing trie node / header not found"。可用 Alchemy / QuickNode /
   Infura(archive) / dRPC / Ankr 付费 archive 等。
3. `solc 0.8.26`：foundry 会按 `foundry.toml` 自动下载，无需手装。

---

## 3. 配置 `.env`

在项目根目录创建 `.env`：
```
RPC_URL=https://eth-mainnet.example.com/v2/<YOUR_ARCHIVE_KEY>
```
`foundry.toml` 已含：
```toml
[rpc_endpoints]
mainnet = "${RPC_URL}"
```
基类 `StrategyBase` 通过 `vm.envString("RPC_URL")` 读取它来 fork。运行前先导入：
```bash
set -a; source .env; set +a
```

---

## 4. 关键 foundry.toml（如果你要合并进已有项目）

如果新项目已有自己的 `foundry.toml`，请确保这些设置存在（否则编译/运行会失败）：
```toml
[profile.default]
src = "src"
test = "strategies"          # ETH PoC 在 strategies/ 下
libs = ["lib"]
solc = "0.8.26"              # 必须
via_ir = true                # 必须（部分 PoC 栈很深，不开会编译失败）
optimizer = true
optimizer_runs = 200
fs_permissions = [{ access = "read", path = "./" }]

[rpc_endpoints]
mainnet = "${RPC_URL}"
```
并把 `remappings.txt` 的四行并入你的 remappings：
```
forge-std/=lib/forge-std/src/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
src/=src/
test/=test/
```
（`test = "strategies"` 是 Foundry 的测试发现目录；若你的项目还有别的测试，可改用
`forge test --match-path "strategies/**"` 只跑这些 PoC，不必改 test 路径。）

---

## 5. 运行

先确保已 `source .env`（`RPC_URL` 已在环境里）。

**编译：**
```bash
forge build
```

**跑全部 147 条（串行，避免 fork 并发打爆 RPC）：**
```bash
forge test -vv --threads 1
```

**只跑某个家族（如 F01）：**
```bash
forge test --match-path "strategies/F01-*/PoC.t.sol" -vv
```

**跑单条策略（两种方式）：**
```bash
# 按路径
forge test --match-path "strategies/F01-07-*/PoC.t.sol" -vvv
# 按测试函数名（每条 PoC 的函数是 testStrategy_FXX_NN）
forge test --match-test testStrategy_F01_07 -vvv
```

**看每条的 PnL 输出**：每个 PoC 在结尾通过 `_endPnL` 打印
```
==== STRATEGY <label> ====
pnl_usd= ...
gas_usd= ...
net_usd= ...
```
用 `-vv` 即可看到这些 `console2.log`。

**带 gas 报告：**
```bash
forge test --match-path "strategies/F01-07-*/PoC.t.sol" --gas-report -vv
```

**强制干净重编译（排查"陈旧字节码"问题时）：**
```bash
forge clean && forge build && forge test --threads 1 -vv
```

---

## 6. 重要说明（务必理解，否则会误读结果）

- **`net_usd` 不是干净的已实现利润。** 基类 `StrategyBase` 的 PnL = 余额变化 +
  `_creditPositionEquity*`（把头寸权益＝抵押−负债，以及很多时候用 `deal()` 免费铸出
  的本金计入）+ 建模 carry。因此较大的 `net_usd` 主要反映**头寸规模/计入的本金**，
  真实经济边缘请以各 PoC 的 `README.md`「PnL math」一节为准。
- **`deal()` / `vm.warp` / `vm.roll` 是测试手段**：PoC 用 `deal()` 注资本金、用
  `warp/roll` 推进时间来结算 carry；这是 fork-replay 研究的标准做法，不是链上真实下单。
- **必须 archive RPC**：fork 历史块需要历史 state，普通节点会失败。
- **串行运行**：`--threads 1` 可避免 147 个 fork 并发把 RPC 限流打爆。
- **via_ir 必开**：部分多腿/闪电贷 PoC 栈很深，关掉 via_ir 会 "stack too deep"。

---

## 7. 故障排查

| 现象 | 原因 / 解决 |
|------|------|
| `vm.envString: environment variable "RPC_URL" not found` | 没 `source .env`，或没设 `RPC_URL` |
| `missing trie node` / `header not found` / fork 在某块失败 | RPC 不是 archive 节点，换 archive |
| `Compilation failed: Stack too deep` | `foundry.toml` 没开 `via_ir = true` |
| 编译报 solc 版本不符 | `foundry.toml` 缺 `solc = "0.8.26"` |
| 大量 429 / 超时 | RPC 限流，加 `--threads 1`，或换更高额度的 RPC |
| 某条 revert | 看该策略 `README.md` 的 `Block pinned` / `Preconditions`；个别策略对区块敏感 |

---

## 8. 目录速览
```
<project>/
├── foundry.toml
├── remappings.txt
├── .env                      # RPC_URL=<mainnet archive>
├── lib/forge-std/
├── src/
│   ├── constants/            # Mainnet.sol, Chainlink.sol
│   └── interfaces/           # amm, cdp, lst, lrt, mm, pendle, stable, synth, bribe, ...
├── test/utils/               # StrategyBase.t.sol, PriceOracle.sol, Whales.sol
└── strategies/
    ├── F01-01-.../PoC.t.sol + README.md
    ├── ...
    └── F18-06-.../PoC.t.sol + README.md   # 共 147 条
```
