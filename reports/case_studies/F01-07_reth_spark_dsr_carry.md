# Case Study 1（跨区块 / multi-block）: F01-07 — rETH × Spark × Maker DSR 三机制套息三角

> 路径: `strategies/F01-07-reth-spark-dai-sdai-carry/`  · 类型: positional（持有 30 天）· 分类: code-invisible
> 真实经济边缘: **+$596 / 30 天 ≈ 2.4% APR**（无杠杆、无清算压力）
> 注意: 报告里的 `net_usd ≈ $146k` 是项目"头寸价值"指标，被免费 deal 的本金/未对冲债务抬高，**不是真实收益**，论文请用 +$596/30d。

---

## 1. 经济动机与新颖性
这条策略把**一份 rETH 抵押品**同时接到三个互不协调的利率/收益引擎上，构成一个跨协议三角：

1. **Rocket Pool rETH**: 收益累积型 LST，其内部兑换率 `getExchangeRate()` 随质押收益单调上升 —— 仅持有 rETH，本金即以 ~3.2% APR 自然增值。
2. **Spark Protocol（Aave v3 分叉）**: 以 rETH 为抵押借出 DAI；Spark 的 DAI 借款利率被刻意锚定在 Maker DSR 之上 ~25–50bp。
3. **Maker DSR（经 sDAI ERC-4626）**: 把借到的 DAI 存进 sDAI 赚存款利率 DSR。

精髓: Spark 借 DAI 的成本（b）与 DSR 收益（仅相差治理设定的 25–50bp）几乎对冲 —— 借/存这条腿近乎零成本；真正的 alpha 来自第三方 **rETH 自身的质押收益**，它叠加在一个 DSR 锚定的低风险稳定币 carry 之上。即: **LST 持有者在不牺牲 rETH 敞口、不加杠杆的前提下，白拿了一层 DSR 锚定的稳定币 carry**。这是"多协议组合产生、单协议视角看不见"的结构性收益。

## 2. 步骤 + 合约调用序列
```
fork @ 19,700,000 (2024-04: DSR≈8%, Spark DAI≈8.5%, rETH yield≈3.2%)
fund: deal(WETH, 100e18)
_startPnL()
-- 诊断读数 --
  Pot.dsr()                                  # DSR 每秒率
  Spark.getReserveData(DAI).currentVariableBorrowRate
-- Leg1  WETH -> rETH --
  rate = rETH.getExchangeRate()              # Rocket Pool NAV
  deal(rETH, 100e18 / rate)                  # 按 NAV 兑成 rETH（注①）
-- Leg2  rETH 抵押进 Spark --
  Spark.getReserveData(rETH)                 # 确认 rETH 已上架
  rETH.approve(SparkPool, max)
  Spark.supply(rETH, amount, this, 0)
-- Leg3  借 DAI（保守 ~60% LTV）--
  Spark.getUserAccountData(this) -> availBorrowsBase
  borrowDai = availBorrows * 63%
  Spark.borrow(DAI, borrowDai, variable=2, 0, this)
-- Leg4  DAI -> sDAI（DSR）--
  DAI.approve(sDAI, max)
  sDAI.deposit(borrowDai, this)              # ERC-4626，赚 DSR
-- Leg5  持有 30 天并结算 --
  vm.warp(+30 days) ; vm.roll(+30d/12)
  Pot.drip()                                 # 结晶 DSR chi
  Spark.supply(rETH, 1)                      # 1 wei 触碰以结晶 Spark 利率指数
-- 读末态: collateral / debt / HF / sDAI 价值 / rETH 率 --
_endPnL()
```
关键合约: rETH `0xae78736C…` · Spark Pool `0xC13e21B6…` · DAI · sDAI `0x83F20F44…` · Maker Pot `0x197E90f9…`

> 注①: 实现上 WETH→rETH 用 `deal()` 按 Rocket Pool 真实兑换率铸入，而非走 Curve（该 rETH/ETH 池仅 ~31 WETH 深度、撑不起 100 ETH，且老式池 `exchange` 返回 void 会 revert）。这是"按真实 NAV 注资"的忠实简化，不影响利率/收益机制的真实性。

## 3. PnL 推导（README 真实口径）
100 ETH（@$2,500）、30 天、LTV 60%:

| 分项 | 公式 | 30 天结果 |
|---|---|---|
| rETH 质押增值 | 100 × 3.2% × 30/365 | +0.263 ETH ≈ **+$657** |
| 借出 DAI | 100×2500×0.60 | 150,000 DAI |
| sDAI 的 DSR 收益 | 150,000 × 8.0% × 30/365 | **+$986** |
| Spark DAI 借款成本 | 150,000 × 8.5% × 30/365 | **−$1,047** |
| **净额** | | **+$596 / 30 天 ≈ +0.24 ETH ≈ 2.4% APR** |

借/存腿净 −$61（近乎对冲），正收益几乎全部由 rETH 质押收益贡献；结构无杠杆、HF 很高、无清算压力。

## 4. 为何 code-invisible
- 全程只调用合法标准入口: `rETH.getExchangeRate`（只读）、`Spark.supply/borrow`（Aave v3 标准）、`sDAI.deposit`（ERC-4626 标准）、`Pot.drip`（公开结算）。
- 每个合约不变量始终成立: Spark 健康度远高于清算线；sDAI 是 1:1 份额会计；rETH 兑换率单调。无重入、无价格/预言机操纵、无回调乱序、无闪电贷。
- 静态分析/模糊测试只看到"一笔抵押借贷 + 一笔储蓄存款"，任何单合约视角都看不出异常。收益来自三个协议利率引擎的结构性错配（rETH 收益 > Spark−DSR 利差），是纯经济层、跨协议、跨区块的边缘。

## 5. 风险（持有期）
- DSR 治理下调快于 Spark DAI 利率 → 对冲腿转负;
- DAI 脱锚 (<0.99) → sDAI 退出时减值;
- Rocket Pool 智能合约 / rETH 脱锚;
- 无杠杆 → 收益为绝对额、不放大。

---

## 6. 流程图骨架（节点 + 箭头，可转 draw.io / TikZ）

### 6.1 资金流图（实线=代币流，虚线=收益/成本计提）
```
nodes:
  P   = "100 WETH (principal)"
  R   = "rETH (Rocket Pool LST)"
  SC  = "Spark: aRETH collateral"
  DBT = "Spark: DAI variable debt"
  SD  = "sDAI (Maker DSR, ERC-4626)"
  Y1  = "rETH NAV up  (+$657, ~3.2% APR)"
  Y2  = "DSR accrual  (+$986, ~8% APR)"
  C1  = "Spark borrow cost (-$1047, ~8.5% APR)"
  NET = "net = Y1 + Y2 - C1 = +$596 / 30d"

solid edges (token flow):
  P   -- deal @ getExchangeRate() -->  R
  R   -- supply() -->                  SC
  SC  -- borrow(DAI, 60% LTV) -->      DBT
  DBT -- sDAI.deposit() -->            SD

dashed edges (accrual over 30 days, via warp + Pot.drip + touch-supply):
  SC  ..accrues..>  Y1
  SD  ..accrues..>  Y2
  DBT ..accrues..>  C1
  Y1 + Y2 + C1  ==>  NET
```

### 6.2 调用时序（sequence diagram 骨架）
```
actors: Test | rETH | Spark | DAI | sDAI | Pot

Test -> rETH :  getExchangeRate()             [read NAV]
Test -> rETH :  (deal: mint rETH = 100 ETH / NAV)
Test -> Spark:  supply(rETH, amt)
Test -> Spark:  getUserAccountData()          [read borrow headroom]
Test -> Spark:  borrow(DAI, 60% LTV, variable)
Test -> DAI  :  approve(sDAI)
Test -> sDAI :  deposit(DAI)                  [ERC-4626]
== vm.warp(+30d); vm.roll ==
Test -> Pot  :  drip()                        [crystallize DSR chi]
Test -> Spark:  supply(rETH, 1 wei)           [crystallize indices]
Test -> Spark:  getUserAccountData()          [final coll/debt/HF]
Test -> sDAI :  convertToAssets()             [final value]
```
