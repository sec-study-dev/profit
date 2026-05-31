# Case 1 — Liquity v2 BOLD 最低利率 Trove 狙击 (F06-03)

## 涉及协议与机制

Liquity v2 是一个去中心化的、以 ETH 系资产为抵押的超额抵押稳定币协议，它发行的稳定币 BOLD **与美元 1:1 软挂钩**（"soft peg" — 不像 USDC 由发行方背书强制 1:1，而是依靠协议机制把市场价拉回 $1 附近，允许短时小幅波动如 $0.997-$1.003）。BOLD 的发行流程是这样的：借款人通过 `BorrowerOperations.openTrove(...)` 抵押 ETH/wstETH/rETH，**自己挑一个年化利率** `_annualInterestRate`，铸造出对应数量的 BOLD。这个利率会实时计息成借款人的债务增长，最终由借款人承担。在 mainnet 部署的合约（`BorrowerOperations.sol` line 201）中，开仓函数的签名是：

```solidity
// liquity/bold/contracts/src/BorrowerOperations.sol
function openTrove(
    address _owner,
    uint256 _ownerIndex,
    uint256 _collAmount,
    uint256 _boldAmount,
    uint256 _upperHint,
    uint256 _lowerHint,
    uint256 _annualInterestRate,     // <<< 借款人自主输入
    uint256 _maxUpfrontFee,
    address _addManager,
    address _removeManager,
    address _receiver
) external override returns (uint256) {
    _requireValidAnnualInterestRate(_annualInterestRate);
    // ...
    sortedTroves.insert(vars.troveId, _annualInterestRate, _upperHint, _lowerHint);
    return vars.troveId;
}

function _requireValidAnnualInterestRate(uint256 _annualInterestRate) internal pure {
    if (_annualInterestRate < MIN_ANNUAL_INTEREST_RATE) revert InterestRateTooLow();
    if (_annualInterestRate > MAX_ANNUAL_INTEREST_RATE) revert InterestRateTooHigh();
}
// MIN_ANNUAL_INTEREST_RATE = 0.5%   MAX_ANNUAL_INTEREST_RATE = 250%
```

## BOLD 的软挂钩与 redemption 设计

BOLD 维持 $1 软挂钩的核心机制叫 **redemption（赎回）** — 任何 BOLD 持有者都可以调用 `CollateralRegistry.redeemCollateral(...)`，把自己手里的 BOLD 烧掉，**按预言机价格 1:1 兑换出等值的 ETH 抵押品**（从某个 trove 借款人的抵押里抽走）。换句话说，协议层面给了 BOLD 一个**硬下界**：任何人持有 1 BOLD 都能换走价值 1 美元的 ETH，这一条规则永远成立。

这个设计的意义在于它构造了一个**自动套利通道**来抑制 BOLD 跌破 peg。设想 BOLD 在 Curve 二级市场跌到 $0.99：套利者立刻可以用 99 cent 在 Curve 上买到 1 BOLD，然后调 `redeemCollateral` 拿回 1 美元的 ETH，毛利润 1 cent。任何理性套利者都会反复执行这个循环，**结果是 Curve 的 BOLD 买盘被疯狂消化、卖盘减少，BOLD 价格自然被推回 $1**。这是协议**设计意图**，不是漏洞 — 协议希望被尽可能多的人盯着这个 redemption 通道并触发它，这就是 BOLD peg 的"市场化执法"。同样地，BOLD 上界由 minter 的自利行为维持（BOLD > $1 时借款人多铸多卖），所以理论上 BOLD 长期在 $0.997-$1.003 这个窄带里震荡。

但 redemption 不可能凭空把 ETH 变出来 — 它必须**从某个具体的借款人的 trove 里拿走 ETH**。"从哪个借款人那里拿"由 `SortedTroves` 决定：这是一条按 `annualInterestRate` 排序的双向链表，redemption 函数沿着**利率从低到高**的方向遍历，依次消化每个 trove 的债务。`TroveManager.redeemCollateral` 内部主循环的核心代码（省略了前面的状态初始化和价格读取）如下：

```solidity
// liquity/bold/contracts/src/TroveManager.sol
if (_maxIterations == 0) _maxIterations = type(uint256).max;
while (singleRedemption.troveId != 0 && vars.remainingBold > 0 && _maxIterations > 0) {
    _maxIterations--;
    // 记录"上一个"trove（即利率更高的相邻 trove）— 当前 trove 处理完后向高利率方向移动
    if (singleRedemption.isZombieTrove) {
        vars.nextUserToCheck = sortedTrovesCached.getLast();
    } else {
        vars.nextUserToCheck = sortedTrovesCached.getPrev(singleRedemption.troveId);
    }

    // ICR < 100% 的 trove 跳过（避免 redemption 反而恶化它的抵押率）
    if (getCurrentICR(singleRedemption.troveId, _price) < _100pct) {
        singleRedemption.troveId = vars.nextUserToCheck;
        singleRedemption.isZombieTrove = false;
        continue;
    }

    // 核心：从当前 trove 抽走 ETH 抵押品、烧掉对应数量的 BOLD
    _redeemCollateralFromTrove(
        defaultPool, singleRedemption, vars.remainingBold,
        redemptionPrice, _redemptionRate
    );

    totalsTroveChange.collDecrease += singleRedemption.collLot;
    totalsTroveChange.debtDecrease += singleRedemption.boldLot;
    vars.remainingBold -= singleRedemption.boldLot;
    singleRedemption.troveId = vars.nextUserToCheck;
    singleRedemption.isZombieTrove = false;
}
```

可以看到协议的循环逻辑非常清晰：从 `getLast()`（利率最低的 trove）开始，**沿着 `getPrev` 一路向利率更高的方向走，直到 BOLD 烧完或者遍历完所有可赎回的 trove**。利率越低的借款人离这个起点越近，redemption 来时就越早被命中。

## 为什么 v2 把利率交给借款人自己设？这不会导致大家都选最低吗？

直觉上"让用户挑利率"似乎一定会触发 race-to-bottom — 既然付的是真金白银的利息，谁不想往最低写呢？但 Liquity v2 在交出这个权利的同时引入了**对偶的代价**：**利率越低，redemption 来临时越早被选中**（就是上面那个 while 循环的命中顺序）。

这把利率从一个"付钱保护协议"变成了一个**显式的拍卖式风险定价**：每个借款人在向协议出价"我愿意为我的 BOLD 债务付多少年化利息"的同时，也在标记"如果有人来 redeem，我愿意第几个被选中"。低利率出价意味着「我对被 redeem 这件事容忍度高，所以我用钱省下利息成本」；高利率出价意味着「我愿意多付利息买一个排在队尾、不被打扰的保护位」。这套设计让协议**不再需要治理或预言机去喂一个全局利率** — 利率分布是由所有借款人的偏好通过这条 sorted list 自洽聚合出来的，类似一个连续清算的 limit order book。

那么**选低利率有什么具体坏处**？被 redeem 单笔看是零经济损失（你失去 X 单位的 ETH 抵押品，同时你的 BOLD 债务减少 X × oracle_price，账面是 zero PnL）。但**被 redeem 在多个非账面维度上对借款人是有成本的**：

- **强制平仓 / 失去仓位**。借款人当初开 trove 是因为他想保留 ETH 敞口、同时获得 BOLD 流动性。redemption 等于强制部分平仓 — 借款人想要的"持有 ETH 加杠杆"目标被打断，原本计划的多头时间 horizon 缩短了。
- **市场价 vs 预言机价的尾差**。redemption 按 `priceFeed.fetchRedemptionPrice()` 结算。当 ETH/USD 在二级市场远高于预言机时（瞬时大波动、CEX-DEX 差价、oracle update 滞后），借款人**以低于市场价的价格被强制卖掉了 ETH**。这个差值经常是 0.1-0.5%，在剧烈行情中能到 1-2%。
- **重开仓的摩擦**。如果借款人事后想恢复原仓位，他需要再开一个新 trove（再付一次 upfront fee）、重新选择利率、重新提供 ETH 抵押。每次被 redeem + 重开都是一笔 gas + 协议费用 + 时间损失。
- **隐性的 BOLD 投机者 PUT**。当借款人选超低利率时，等于把"BOLD 短期下方风险"无偿写给了所有 BOLD 持有者：只要 BOLD 跌到 redemption 套利空间打开，BOLD 持有人就会找最低利率 trove 兑现这个 PUT。借款人通过 0.5% 利率省下来的钱可能远不够覆盖这种"日常被狙击"的累积损失。

**那为什么选高利率有好处？** 最直接的好处是 **redemption 队列的保护位**。一个 12% 利率的 trove 在 `SortedTroves` 里离起点（`getLast()`）很远；除非 BOLD 极度脱锚或低于他利率的所有 trove 都被掏空，否则 redemption 流量永远不会到他这里。**他是在用每年多付的几个百分点利息买一个"我自己决定何时关仓"的看跌期权**。对于长持仓不愿被打断的借款人（比如想穿越整个牛市周期持有 ETH 敞口的 LP），这个保险费是值得付的。

理想均衡是借款人按自己的**时间偏好和风险承受度**分布到不同利率档：

- 极短期 / 套利型借款人 → 低利率，反正持仓不需要保护多久
- 长期 LP → 高利率，要求稳定不被打扰
- 中间 trader → 中等利率随市场波动调整

均衡偏离这个理想分布的来源恰恰是攻击者的 alpha 来源 — 借款人系统性低估了"被狙击概率"，因为这一项不像利息账单那样每天看得见。

## 每个机制独立看都是安全的

**借款人自主设利率** — 利率有上下限 (0.5% ≤ r ≤ 250%)，借款人可以随时通过 `adjustTroveInterestRate` 调整（付一笔 upfront fee），激励完全对齐自己的债务成本。这是典型的"让用户为自己的风险定价"的市场化设计。

**SortedTroves** — 教科书式的双向链表，所有插入/删除带 hint 加速；排序键单调、公开、可查。借款人可以在开仓前先 `getFirst()/getLast()` 看清当前队列再下决定。

**redeemCollateral 按 face value 兑换** — 这是 BOLD peg 维持机制的核心；被 redeem 的借款人**账面 PnL ≈ 0**（损失抵押品 = 减少的债务）。

**DssFlash** — 必须 atomic 归还，违反则全 tx revert。零费用是 Maker 治理的鼓励流动性决策。

**Curve BOLD/USDC** — 标准 Stableswap-NG，invariant 严格守恒。

每个机制都通过了独立审计，每个设计选择都有清晰的局部最优性论证。

## 组合后为什么能获利

把这五个机制串到同一笔交易里，攻击者无需任何本金就能套利。完整流程：

1. 查 `SortedTroves.getLast()`，找到当前利率最低的 trove `T*`，记录它的剩余债务 `debt(T*)`。
2. 查 Curve BOLD/USDC 报价：如果 BOLD < $1（甚至只是 30 bp 的偏离），就有套利空间。
3. 设定本次 redemption 名义 `N = min(debt(T*) + 一点缓冲, 想要的目标规模)`，确保 redemption 不会爬到利率更高的下一个 trove。
4. 调用 `DssFlash.flashLoan(this, DAI, N')` 借出 `N'` DAI（`N' ≈ N × BOLD_price + swap drag`），用同笔交易内的回调 `onFlashLoan` 完成下面所有步骤。
5. 在回调里：DAI → USDC（Curve 3pool） → BOLD（Curve BOLD/USDC 池），按低于 face 的市场价买到约 `N` 个 BOLD。
6. 用买到的 BOLD 调用 `CollateralRegistry.redeemCollateral(N, MAX_ITERS, MAX_FEE_PCT)`。协议从 `SortedTroves` 队尾开始遍历，把 `T*` 的债务清掉（如果 `N` 没用完，继续 `getPrev` 找下一个利率最低的 trove），按 `redemptionPrice` 把对应的 ETH 转给攻击者。
7. ETH wrap 成 WETH，再 WETH → USDT（Curve tricrypto2） → DAI（Curve 3pool）。
8. 还 `N'` DAI 给 `DssFlash`，回调返回 ERC-3156 magic value，flashloan 成功平账。
9. 净收益 ≈ `(1 - BOLD_market_price) × N - redemption_fee × N - swap_drag - gas`。BOLD 偏离 peg 30 bp、$1M notional 时单笔约 $3,000。

关键不是利润大小，**而是这笔利润是由谁在赔**：被 redeem 的最低利率 trove 借款人。他失去的是 ETH 抵押品 — 以 `priceFeed.fetchRedemptionPrice()` 的预言机价计价 — 而他若是按自己计划自然平仓（卖 ETH 换 BOLD 还债），成本会和**那一刻的市场行情**挂钩，包括 CEX/DEX 当下的真实 ETH 价、自己选时机、利用 limit order 等手段。redemption 把这两者强行解耦：你的关仓时机被一个**追求 BOLD peg 收敛的套利者**决定，你的 ETH 卖出价被一个**可能滞后的预言机**决定。当 ETH/BOLD 二级市场出现错配（比如 ETH 现货 $3,005 但 oracle 还在更新到 $3,000；或者 BOLD 跌到 $0.995 创造了 50 bp 的赎回价差），redemption 就把这个错配的损失**精确地、确定性地转嫁给了恰好位于队头的那个借款人** — 攻击者赚的就是借款人这笔被强制平仓里损失的那 30-100 bp。

更糟的是这种损失是**系统性反复发生**的。借款人为了省 1-2% 年化利息选了低利率，结果**只要 BOLD 偏离 peg 30 bp 以上，他就会被 redeem 一次** — 而 BOLD 偏离 peg 30 bp 这件事在二级市场任何一次小冲击下都会发生（一次大额 BOLD 卖单、稳定币赎回潮、ETH 价跳水带动 trove 借款人恐慌卖出 BOLD 等等）。每被 redeem 一次，借款人就吃一次"市场价 - 预言机价 + redemption_fee"的隐性损失。把"被狙击频率 × 单次损失幅度"累加起来，一年下来可能吃掉远超 1-2% 利率节省的成本。借款人当初做的决策是"我用 0.5% 利率代替 5% 利率，每年省 4.5%"，但他**没意识到自己其实做的是"我用 4.5%/年的利息节省，去 short 一份 BOLD-USD 短期波动率"** — 而 BOLD-USD 短期波动率不为零，而且攻击者用 DssFlash 把"行权门槛"压到了零，于是 BOLD 每打一个 wobble，借款人就被自动行权一次。这正是上面说的"BOLD 短期下方风险的 PUT，被低利率借款人无偿写给了所有 BOLD 持有者"。

## 为什么不容易被识别

第一，**链上观察者看到的攻击交易和一个普通的 BOLD peg-keeping redemption 在形式上完全一致**。`CollateralRegistry.redeemCollateral` 本身就是协议预期被频繁调用的公开函数 — 每次 BOLD 偏离 peg 都会有合法套利机器人来调它把价格压回去，这是协议设计意图。"合法的 peg 维持"和"针对性的低利率狙击"在 calldata 上根本无法区分。

第二，**没有任何一方能单独看到完整图景**。Maker 看到的只是一笔 DAI flashmint，对它而言是余额短暂腾挪；Curve BOLD/USDC 看到的是一对 swap；Liquity v2 看到的是一次合法 redemption；被狙击的借款人甚至可能完全没意识到自己被针对了 — 他的钱包只是显示"我的债务被部分清偿，我的 ETH 抵押少了等值的一份"。要识别攻击需要把四个独立协议的 telemetry 在同一笔 tx 内做 cross-correlation，**没有协议有动机或能力构建这个跨协议监视层**。

第三，**借款人没有信号去更新风险模型**。被 redeem 一次后，借款人的 trove 抵押率反而提升了（债务减少快于抵押品减少），局部看像是"我变安全了"。需要把月度被 redeem 频率累计、再换算成机会成本，借款人才会意识到这是一个慢性失血。这种"慢性、感觉良好的损失"远比一次性爆雷更难发现。
