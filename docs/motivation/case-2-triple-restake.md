# Case 2 — EigenLayer + Symbiotic + Karak 三重再质押 (F18-05)

## 涉及协议与机制

再质押 (restaking) 是 2024 年兴起的一类 DeFi 协议：用户把已经在 staking 的 ETH（以 LST 形态如 stETH / wstETH / weETH 持有）再次存进一个 restaking 协议，将这份资本"同时"承诺给一组叫做 Actively Validated Services (AVS) 的下游协议作为安全后盾，并领取 restaking 协议给的 points/airdrop 作为回报。截至 2024 年中至少有三个独立的再质押协议在以太坊主网运行：EigenLayer、Symbiotic、Karak。三者工程实现各不相同但接口都很简单。

**EigenLayer** 通过 `StrategyManager.depositIntoStrategy` 接受用户存入的 LST，token 转给某个 Strategy 合约，按内部账本给用户记 shares（`StrategyManager.sol`）：

```solidity
// Layr-Labs/eigenlayer-contracts/src/contracts/core/StrategyManager.sol
function depositIntoStrategy(IStrategy strategy, IERC20 token, uint256 amount)
    external onlyWhenNotPaused(PAUSED_DEPOSITS) nonReentrant returns (uint256 depositShares)
{
    depositShares = _depositIntoStrategy(msg.sender, strategy, token, amount);
}

function _depositIntoStrategy(address staker, IStrategy strategy, IERC20 token, uint256 amount)
    internal onlyStrategiesWhitelistedForDeposit(strategy) returns (uint256 shares)
{
    token.safeTransferFrom(msg.sender, address(strategy), amount);  // 1. 锁住 token
    shares = strategy.deposit(token, amount);                       // 2. 由 strategy 计算 shares
    _addShares(staker, strategy, shares);                           // 3. 记到 staker 名下
    delegation.increaseDelegatedShares(...);
    return shares;
}
```

**Symbiotic** 的 `DefaultCollateral` 是结构上更简单的 ERC-20 vault — 存入 LST 直接 1:1 mint vault token（`DefaultCollateral.sol`）：

```solidity
// symbioticfi/collateral/src/contracts/defaultCollateral/DefaultCollateral.sol
function deposit(address recipient, uint256 amount) public nonReentrant returns (uint256) {
    uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
    IERC20(asset).transferFrom2(msg.sender, address(this), amount);
    amount = IERC20(asset).balanceOf(address(this)) - balanceBefore;

    if (amount == 0) revert InsufficientDeposit();
    if (totalSupply() + amount > limit) revert ExceedsLimit();

    _mint(recipient, amount);                                       // recipient 拿 1:1 vault token
    emit Deposit(msg.sender, recipient, amount);
    return amount;
}
```

**Karak** 的 vault 遵循 ERC-4626 标准，调用模式同上。三个协议都把"deposit 锁住的 LST 数量"作为自己向下游 AVS 承诺的安全敞口的计量基础。

## 每个机制独立看都是安全的

三个协议在做自己 risk model 时，各自的 invariant 都是局部一致的：

- **EigenLayer**：`strategy.totalShares × sharePrice == strategy.heldTokens`。Strategy 合约里实际持有多少 stETH，账本上就承诺多少 stETH 可以被 AVS slashing。**资产托管和承诺敞口在合约内部严格守恒**。
- **Symbiotic**：`totalSupply() == 自己 vault 里的 wstETH 余额`（每次 `deposit` 都先量真实 `balanceBefore`/`balanceAfter` 再 mint，杜绝了 inflation attack）。同样守恒。
- **Karak**：标准 ERC-4626 share/asset 绑定，`convertToAssets(totalSupply()) == totalAssets()`。同样守恒。

每个协议都能形式化地证明：「**我合约里锁着多少 LST，我向 AVS 网络承诺的安全敞口就只有这么多 LST**。」用户存进来的 token 在 protocol 层面**是真实存在、可被 slash 的**。从单协议视角看，这是合理且安全的设计。

LST（stETH / wstETH / weETH）作为 ERC-20 资产的可流通性也是 Lido / EtherFi 等 LST 协议的核心设计目标 — 让 staked ETH 在 DeFi 生态里成为一等公民。这本身没有任何问题，wstETH 在 Curve 做 LP、在 Aave 做抵押都是合理用法，因为这些下游协议**不依赖 LST 的独占性假设**。

## 组合后为什么能获利

用户的执行流程非常朴素，没有任何 trick。完整流程：

1. 准备资金：用户持有 150 ETH 等价物的资本，事先在 Curve 上把它换成三份不同 LST 形态 — 50 stETH（Lido 直接 stake）、50 wstETH（stETH 的 wrap）、50 weETH（EtherFi LRT，底层已经在 EigenLayer 再质押一次）。三份 token 都各自合法持有，区块链层面没有任何"共享"概念。
2. **Leg A — EigenLayer**：approve `stETH` 给 `StrategyManager`，调 `depositIntoStrategy(stETH_strategy, stETH, 50e18)`。EigenLayer 把这 50 stETH 锁进自己的 strategy 合约，给用户记一笔 EigenLayer shares。EigenLayer 的账本现在显示"我有 50 stETH 的可被 slash 抵押品在背书我的 AVS 网络"。
3. **Leg B — Symbiotic**：approve `wstETH` 给 `DefaultCollateral` vault，调 `deposit(this, 50e18)`。Symbiotic 把 50 wstETH 锁进 vault，1:1 给用户 mint 50 个 vault share token。Symbiotic 的账本现在显示"我有 50 wstETH 的可被 slash 抵押品在背书我的 networks"。
4. **Leg C — Karak**：approve `weETH` 给 Karak vault，调 ERC-4626 `deposit(50e18, this)`。Karak 把 50 weETH 锁进 vault，给用户 mint 对应的 vault share。Karak 的账本现在显示"我有 50 weETH 的可被 slash 抵押品在背书我的 operators"。
5. 用户的回报开始并行累积：EigenLayer 积累 EIGEN points（基于 50 stETH × 持有时间）、Symbiotic 积累 SYMB points（基于 50 wstETH × 持有时间）、Karak 积累 KAR points（基于 50 weETH × 持有时间）+ EtherFi loyalty points（来自 weETH 本身）+ 又一份 EigenLayer points（因为 weETH 底层已经替持有人 restake 进 EigenLayer 了）。
6. 关键事情发生在协议级账本上：三个协议各自记录"我有 50 ETH 等价的可被 slash 抵押品"，三家相加是 **150 ETH 的承诺 security commitment**。但**实际可被同步 slash 的本金最多就是用户的 150 ETH** — 三份 LST 来自同一个 ETH 验证人池，是同一份经济价值在三份不同的 ERC-20 外壳里。
7. 当某天一次系统性事件触发三个协议同时尝试 slash 时，三家都会发现"我手里那 50 ETH 已经被另一个协议的 slash 清空了" — 这就是传统金融里 2008 年雷曼把 prime broker 们集体拖下水的 **rehypothecation chain risk**，在 DeFi 里以一种**完全合规、无人察觉**的形式重新出现。

每个机制单看都没错。错位的是协议之间一个**从未被任何 invariant 强制保护**的共同假设：「我 vault 里这份 LST 是 *独占地* 为我背书的」。这个假设来自 TradFi 法律里的 collateral exclusivity 原则，但 LST 作为 ERC-20 显然不具备链上独占性 — 同样一份 wstETH 的 `balanceOf` 既可以在 EigenLayer 的 strategy 合约里、也可以（通过用户拥有的另一份 wstETH）在 Symbiotic 的 vault 里 — **没有任何链上结构强制保证「同一份 ETH 至多对应一个 restaking 承诺」**。用户拿到了 5x 的 points 暴露，三家协议合计承诺了 3x 的安全敞口，underlying 资本却只有 1x。

## 为什么不容易被识别

第一，**这根本不是一个传统意义上的「攻击」**。没有 reentrancy、没有溢出、没有任何合约状态被破坏。每个协议的内部不变量在任一时刻都严格成立 — 审计员去逐合约审计永远查不出问题。

第二，**"问题"只在一个没人构建的视角里存在**。EigenLayer 的链上数据告诉它"我有 X ETH stETH 抵押品"，Symbiotic 看到"我有 Y wstETH"，Karak 看到"我有 Z weETH"。三个数字加起来超过实际经济价值的事实，**只有一个跨协议聚合视角才能察觉**，而构建这个视角既不在任何单一协议的产品路线图里，也不在任何监管框架的要求里 — 整个生态默认每个协议"各扫门前雪"。

第三，**风险只在尾部事件中显形**。在正常运行的所有时间里，三个协议都不需要 slash，于是"同一份 ETH 同时承诺给三家"这件事看起来像免费收益。直到某天 AVS 真的触发 slashing，三个协议同时去找用户那 50 ETH 时才会发现钱已经被先到的 slash 拿光 — 但那时候已经晚了，每个协议都需要去解释为什么自己向下游 AVS 承诺的 security 实际上是"打折券"。这种风险的 **realised probability ≈ 0**（短期），但 **realised loss when triggered ≈ 100%** 且**会同时砸三个协议**。链上探测不到，链下也很难建模。
