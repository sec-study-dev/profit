# Case Study 2（单区块 / atomic）: F16-02 — GHO ↔ crvUSD 跨 CDP 利率套利

> 路径: `strategies/F16-02-gho-vs-crvusd-rate-arb/`  · 类型: atomic（单笔交易）· 分类: code-invisible
> 真实经济边缘: **+$4,600 / 年 ≈ 2.3% APR 回扣**（每 $200k GHO 债务），~29 天回本
> 注意: 报告里的 `net_usd ≈ $122k` 是"免费 deal 的 50 wstETH（≈$13.8万）+ LLAMMA 头寸权益"被计入 PnL 的结果，**不是利率套利收益**，论文请用 +$4,600/年。

---

## 1. 经济动机与新颖性
GHO 与 crvUSD 都是超额抵押 CDP 稳定币，但定价债务成本的引擎完全不同、互不协调:
- **GHO（Aave）**: 借款 APR 由链下治理设定，与利用率脱钩、变动迟缓（2024 年 ~9–9.5%）；治理为护盘倾向维持高位。
- **crvUSD（Curve）**: 借款利率由 PegKeeper 算法每区块自动调整 —— crvUSD<$1 升息、>$1 降息；稳于 1 美元上方时 wstETH 市场借款率落到 ~6.5%。

两套引擎不通信，于是 `r_GHO − r_crvUSD` 形成结构性、且历史上长期为正的利差。本策略捕捉的是**"利率"而非"价格"**的错配（多数原子套利吃价差，这条吃利率基差），概念更新颖。利用方式: **机会型再融资** —— 当 GHO 比 crvUSD 贵 ≥ 阈值时，把 GHO 债务迁移到更便宜的 crvUSD 侧。

## 2. 步骤 + 合约调用序列
```
fork @ 20,500,000 (2024-09: GHO≈9.0%, crvUSD-wstETH≈6.5%, basis≈+250bp)
setUp: track wstETH / crvUSD / USDC / GHO
-- 1) 读两套利率 --
  AaveV3Pool.getReserveData(GHO).currentVariableBorrowRate -> ghoApyBps(~900)
  LLAMMA(crvUSD wstETH AMM).rate()  (回退 Controller.monetary_policy().rate())
                                    -> crvUsdApyBps(~650)
-- 2) 计算基差并判定 --
  basis = ghoApyBps - crvUsdApyBps  ~= +250bp
  if basis < 100bp: return          # 不足阈值则不交易（保护性退出）
-- 3) 执行"便宜腿"（开 crvUSD 贷）--
  deal(wstETH, 50e18) ; _startPnL() ; vm.txGasPrice(20 gwei)
  wstETH.approve(crvUSD_Controller, 50e18)
  Controller.max_borrowable(50, 10 bands)              # 校验额度
  Controller.create_loan(50 wstETH, 100,000 crvUSD, 10 bands)
-- 4) crvUSD -> USDC（"合成 GHO"）--
  crvUSD.approve(Curve_crvUSD_USDC_NG, 100k)
  Curve.exchange(1->0, 100k, 0) -> ~100k USDC
-- 5) 记账 --
  annualSavings = USDC * basis      # 仅 emit 日志（真实经济价值）
  Controller.user_state -> 抵押/债务 ; _creditPositionEquityE6(...)
_endPnL()
```
关键合约: Aave V3 Pool `0x87870Bca…` · GHO `0x40D16FC0…` · crvUSD wstETH Controller `0x100dAa78…` · LLAMMA AMM `0x37417B22…` · Curve crvUSD/USDC NG `0x4DEcE678…`

> 实现说明: PoC 只执行了便宜腿（借 crvUSD→换 USDC，得到可偿还 GHO 的"合成 GHO"），**并未真的去平掉一笔 GHO 债**（无状态测试里没有现成 GHO 仓）。它把可实现的合成-GHO 金额与隐含年化节省记入日志 —— 这就是真实经济价值所在。

## 3. PnL 推导（README 真实口径）
待再融资 GHO 债务 D=200,000、r_GHO=9.0%、r_crvUSD=6.5%、换币成本 20bp:

| 分项 | 公式 | 结果 |
|---|---|---|
| 年化利息节省 | D × (r_GHO − r_crvUSD) = 200k × 2.5% | **+$5,000/年** |
| 一次性换币成本 | D × 20bp | −$400 |
| **净现值（1 年）** | | **+$4,600/年 ≈ 2.3% APR 回扣** |
| 回本周期 | $400 / $5,000 | **≈ 29 天** |

## 4. 为何 code-invisible
- 边缘根源是两套利率引擎结构性不协调（链下治理 vs 链上算法），本身不是任何合约 bug。
- 捕捉它只用合法只读 + 合法开仓/换币: `getReserveData / rate / max_borrowable / create_loan / exchange`。crvUSD 贷款健康、Curve 交换遵守池不变量，无操纵、无重入、无乱序、无闪电贷。
- 代码层看只是"一笔正常 crvUSD 抵押开仓 + 一次 Curve 稳定币兑换"，静态分析/模糊测试无法将其与普通借贷区分，更无法识别背后的"跨 CDP 利率再融资套利"意图。单区块、原子、code-invisible。

## 5. 风险
- 利率反转: crvUSD 算法可在 crvUSD 脱锚时单区块把利率拉到 GHO 之上 → 需持续监控、基差反转即平;
- 换币深度: crvUSD/USDC 与 GHO/USDC 池较浅，>$5M 有可观滑点;
- GHO 治理降息（1 天冷却）压缩基差;
- 清算曲线差异: Aave 健康因子 vs LLAMMA 软清算带，迁债改变风险画像。

---

## 6. 流程图骨架（节点 + 箭头，可转 draw.io / TikZ）

### 6.1 决策 + 资金流图
```
nodes:
  GHO_R = "Aave: GHO borrow APR (governance-set ~9.0%)"
  CRV_R = "Curve: crvUSD-wstETH APR (algorithmic ~6.5%)"
  BASIS = "basis = r_GHO - r_crvUSD  (~+250bp)"
  GATE  = "basis >= 100bp ?"
  STOP  = "return / no trade"
  W     = "50 wstETH (collateral)"
  LOAN  = "crvUSD LLAMMA loan (100k crvUSD, 10 bands)"
  USDC  = "USDC = synthetic GHO"
  REPAY = "repay GHO debt on Aave (off-PoC)"
  SAVE  = "interest saving = D*(r_GHO - r_crvUSD) = +$4,600/yr"

edges:
  GHO_R --> BASIS
  CRV_R --> BASIS
  BASIS --> GATE
  GATE  -- no  --> STOP
  GATE  -- yes --> W
  W     -- create_loan() -->          LOAN
  LOAN  -- Curve.exchange(crvUSD->USDC) --> USDC
  USDC  ..(off-PoC refi leg)..>       REPAY
  REPAY ==>                           SAVE
```

### 6.2 调用时序（sequence diagram 骨架）
```
actors: Test | AaveV3Pool | LLAMMA(crvUSD AMM) | Controller | crvUSD | CurveNG | wstETH

Test -> AaveV3Pool : getReserveData(GHO)        [read r_GHO ~9.0%]
Test -> LLAMMA     : rate()                      [read r_crvUSD ~6.5%]
                     (fallback: Controller.monetary_policy().rate())
Test               : basis = r_GHO - r_crvUSD
Test               : if basis < 100bp -> STOP
Test -> wstETH     : approve(Controller)
Test -> Controller : max_borrowable(50, 10)      [check headroom]
Test -> Controller : create_loan(50 wstETH, 100k crvUSD, 10 bands)
Test -> crvUSD     : approve(CurveNG)
Test -> CurveNG    : exchange(crvUSD -> USDC)    [~100k USDC]
Test -> Controller : user_state()                [coll/debt]
== off-PoC ==
(USDC -> repay GHO on Aave; realise interest saving)
```
