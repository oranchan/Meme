# MemeToken 项目需求文档

> 本文档不是理想化蓝图，而是对当前代码库（`MemeToken.sol`, `TradingLimiter.sol`, `TaxManager.sol`, `LiquidityManager.sol`）真实功能的还原与结构化说明，用于：
> 1. 快速理解当前版本具备 / 不具备的能力
> 2. 明确后续可扩展点
> 3. 供测试、审计与二次迭代参考

---
## 1. 概述
当前项目实现了一个带有：
- 差异化税费（买 / 卖 / 普通转账不同税率）
- 基于总量百分比的交易限额（单笔、单钱包持仓）
- 简单的 24 小时内交易次数限制
- 初始 + 追加流动性管理（基于 Uniswap V2 风格接口）

的 ERC20 Meme Token。税费目前仅记录在 `TaxManager` 内部分类计数，不进行真实分发、销毁或自动加池。所有限制参数为部署时固化，不支持链上重新配置。

---
## 2. 合约列表与职责
| 合约 | 角色 | 职责 | 可配置性 |
|------|------|------|----------|
| `MemeToken` | 核心代币 | ERC20；执行税费计算与交易限制；owner 可增发、设置 AMM Pair、设置税费豁免 | 仅支持：增发、设置是否为 AMM Pair、设置税费豁免 |
| `TradingLimiter` | 限制器 | 固定规则：单笔≤总供给1%；单钱包≤2%；24h 内≤20次交易 | 无 owner；参数不可变（部署时计算） |
| `TaxManager` | 税费分类账 | 计算固定税率；记录分配（Marketing / Liquidity / Development / Burn 四分类计数） | 无 owner；税率与比例固定 |
| `LiquidityManager` | 流动性管理 | 首次初始化（token + ETH）创建或复用 pair 并铸造 LP；后续任意用户可追加流动性（Router 路径） | owner 仅用于初始 `initLiquidity` 调用 |

---
## 3. 关键功能（按实际实现）
### 3.1 代币基本信息
- 名称：`MemeToken`
- 符号：`MEME`
- 精度：18
- 初始供应：构造函数参数 * 10^18 后一次性 mint 给部署者
- 支持后续 `owner.mint()` 增发（无上限逻辑）

### 3.2 交易类型识别
- 通过 `isAMMPair[address]` 判断：
  - `from` 是 AMM Pair => 视为“买入”
  - `to` 是 AMM Pair => 视为“卖出”
  - 都不是 => 普通“转账”

### 3.3 税费逻辑（固定不可调）
| 场景 | 税率 | 调用函数 | 说明 |
|------|------|----------|------|
| 买入 | 5% | `TaxManager.calculateTaxInBuys` | 先校验接收者限制后计算税 |
| 卖出 | 8% | `TaxManager.calculateTaxInSells` | 仅校验卖出地址交易频次 |
| 转账 | 2% | `TaxManager.calculateTaxInTransfers` | 双方频次 & 接收者余额限制 |

处理方式：
1. 计算税额 `tax`
2. `tradeAmount = amount - tax`
3. 先把 `tradeAmount` 发送给接收者
4. 再将税额从发送者转入 `TaxManager` 合约地址
5. 调用 `TaxManager.allocateTax(tax)` 更新四分类累计值（仅数值记录，不做额外操作）

豁免：若 `from` 或 `to` 在 `taxExempt`，则直接按原始 `amount` 调用父类 `_update`，跳过税与限制。

### 3.4 交易限制（全部固化）
| 限制项 | 数值 | 来源 | 校验位置 |
|--------|------|------|----------|
| 单笔最大 | 总供应量 / 100 (1%) | `TradingLimiter` 构造计算 | `_update` 前置 `isTradeAllowed` |
| 单钱包最大 | 总供应量 / 50 (2%) | 构造计算 | 买入/转账前、买入/转账后再次检查 |
| 日交易次数 | 24h 内 < 20 次 | `tradeCount` + `lastTradeTime` | 视场景对 from/to 调用 `canTrade` |
| 计数窗口 | 24h = 86400 秒 | 固定常量 | `canTrade` / `recordTrade` |

计数策略：
- 新周期判断：当前时间与 `lastTradeTime[address]` 差值 ≥ 86400 => 重置计数
- 记录：不同场景对参与方调用 `recordTrade`

### 3.5 流动性管理
#### 初始化 `initLiquidity`
- 限定 `LiquidityManager.owner`
- 输入：`tokenAmount` 与随交易发送的 ETH
- 步骤：
  1. 若 `pair` 未设置：调用 Factory `getPair`，若无则 `createPair`
  2. 从 owner `transferFrom` 拉取指定 token 数量（实际记账用合约余额兜底）
  3. 将 ETH 包装为 WETH
  4. 将 token 与 WETH 转入 Pair
  5. 调用 `pair.mint(owner)` 获取 LP（记录到 `liquidity[owner]`）
  6. 标记 `initialized = true`

#### 追加流动性 `addLiquidityETH`
- 任何人可调用（需先对 `LiquidityManager` 授权 token）
- 逻辑：
  - 将代币转入本合约
  - 授权 Router
  - 调用 `router.addLiquidityETH`

### 3.6 角色与权限
| 行为 | 权限主体 |
|------|----------|
| mint 代币 | `MemeToken.owner()` |
| 设置 AMM Pair | `MemeToken.owner()` |
| 设置税费豁免地址 | `MemeToken.owner()` |
| 初始化流动性 | `LiquidityManager.owner()` |
| 追加流动性 | 任意地址（初始化完成后） |
| 交易 / 转账 | 任意地址（满足限制） |

### 3.7 事件
- 仅定义：`event Mint(address indexed to, uint256 amount);`
- 未对税费、限额、流动性、豁免变更添加事件（审计与追踪可读性较弱）

### 3.8 Reentrancy / 安全
- `MemeToken` 继承 `ReentrancyGuard`，但当前 `_update` 中无外部可重入调用（除内部合约 `TaxManager` 的纯状态写入），因此防护为冗余/预留。
- 无 `pause` / `blacklist` / `upgrade` 机制。

---
## 4. 状态变量摘要（核心）
| 合约 | 变量 | 含义 |
|------|------|------|
| MemeToken | `tradingLimiter` | 限制器实例 |
| MemeToken | `taxManager` | 税费管理实例 |
| MemeToken | `isAMMPair[address]` | 是否为 AMM Pair 地址 |
| MemeToken | `taxExempt[address]` | 税费与限制豁免标记 |
| MemeToken | `tax` | 最近一次 `_update` 计算出的税额 |
| TradingLimiter | `maxTradeAmount` | 单笔交易上限 |
| TradingLimiter | `maxAccountBalance` | 单钱包可持有上限 |
| TradingLimiter | `lastTradeTime[address]` | 上次记账时间戳 |
| TradingLimiter | `tradeCount[address]` | 当前 24h 已计数次数 |
| TaxManager | `marketingTax` 等四分类 | 累积的税额分类计数 |
| LiquidityManager | `pair` | Token/WETH 交易对地址 |
| LiquidityManager | `initialized` | 是否完成首次流动性 |

---
## 5. 核心流程
### 5.1 代币转账 `_update(from, to, amount)`
1. 若 `from==0` 或 `to==0` => 直接父逻辑（铸造/销毁）
2. 若任一地址豁免 => 直接父逻辑
3. 分类（买/卖/转账）
4. 前置校验：单笔大小、余额上限（取决于场景）、频次限制
5. 按场景计算税额 & 得到净额
6. 先转净额，再转税额到 `TaxManager`
7. 调用 `allocateTax` 分类记账
8. 后置校验（买入/普通转账场景下再次检查接收者余额）
9. 记录交易次数（不同场景作用对象不同）

### 5.2 交易次数逻辑
- `canTrade(account)`：
  - 若距 `lastTradeTime` ≥ 86400 => 返回 true（视为新周期）
  - 否则：`tradeCount < 20`
- `recordTrade(account)`：
  - 若 ≥ 86400 重置计数与时间
  - 计数 +1 并更新时间

### 5.3 流动性初始化
详见第 3.5；无自动添加或拆除逻辑。

---
## 6. 现存局限 / 风险
| 类别 | 问题 | 影响 |
|------|------|------|
| 税费 | 税率硬编码，无法调整 | 市场变化无法响应 |
| 分配 | 仅数值累计，不做真实资金分流 | 无实质用途；需手动后续处理 |
| 权限 | 无法撤销增发权限 / 无多签 | 单点风险 |
| 限制 | 无法动态修改上限 | 项目生命周期不同阶段无法调参 |
| 安全 | 无暂停/黑名单 | 遇紧急状况无法快速冻结 |
| 监控 | 缺少事件 | 外部索引 / 分析困难 |
| `recordTrade` | 外部可随意调用（非仅 Token） | 可被刷高 tradeCount 干扰频次（轻度 DoS） |
| 逻辑 | 追加流动性函数未校验最小滑点 | 价格可能被夹攻击时不安全 |

---
## 7. 非功能需求（从代码推断）
| 项目维度 | 说明 |
|----------|------|
| 性能 | 逻辑简单，每笔多 1~2 次状态写入，可接受 |
| Gas 优化 | 未使用自定义错误、unchecked、事件裁剪等优化手段 |
| 可读性 | 已添加英文 NatSpec 注释（最近一次改动） |
| 可升级性 | 无代理、不可升级 |

---
## 8. 建议的测试用例（覆盖当前实现）
1. 初始部署：总供给正确，限制参数与预期匹配
2. 交易分类：买/卖/转账税率差异验证
3. 税额计算：边界（1 token、最大单笔）
4. 限制：
   - 单笔 > 1% revert
   - 接收者余额逼近 2% 后再次买入 / 转账应 revert（前/后置）
   - 24h 内第 21 次交易 revert，跨窗口重置成功
5. 豁免：设置后无税且不受限
6. Mint：新铸代币不触发税/限制
7. 流动性：
   - `initLiquidity` 仅能调用一次
   - `addLiquidityETH` 成功添加
8. TaxManager：`allocateTax` 累计四分类比例正确（40/30/20/10）
9. `recordTrade` 外部直接调用对频次影响（评估是否需要修复）

---
## 9. 未来扩展建议（不属于当前实现）
| 方向 | 说明 |
|------|------|
| 动态税率 | 引入可调税率 + 上限防滥用 |
| 真实分配 | 将税费自动分成：营销地址、LP 自动注入、销毁地址等 |
| 安全控制 | 增加 Pausable、緊急 owner 转移、多签保护 |
| 事件补全 | 记录 tax 扣除、限额触发、豁免变更、流动性事件 |
| 白名单预热 | 上线初期仅允许少量地址交易，逐步开放 |
| 黑名单 | 防御已知攻击合约/MEV 机器人 |
| 频次模型优化 | 滑动窗口或令牌桶避免“重置瞬间集中刷交易” |
| 反射 / 分红 | 引入持有人分红或质押模块提高粘性 |
| 自动做市 | 定期再平衡 / 价格波动控制策略 |
| 可升级性 | 使用透明代理或 UUPS 设计 |

---
## 10. 验收标准（面向当前版本）
| 条目 | 标准 |
|------|------|
| 部署成功 | 合约地址可用，初始参数正确 |
| 基本转账 | 正常完成，税费与净额符合预期 |
| 限制触发 | 超限操作全部 revert 且信息可复现 |
| 流动性初始化 | 仅一次成功，LP 到 owner |
| 追加流动性 | 多账户成功添加，无状态污染 |
| 频次限制 | 第 21 次交易阻止，窗口后恢复 |
| 税费分类 | 四项累计数值符合比例关系 |
| 代码审阅 | 无明显重入 / 溢出 / 未检查外部调用风险 |

---
## 11. 结论
当前实现为一个“最小可运行”含税 + 简单限控 + 手动流动性 的 Meme Token 原型：
- 适合教学 / Demo / 内部测试
- 不适合直接主网生产（缺乏动态控制、安全应对与资金分发）

若要进入正式运营阶段，建议优先：
1. 增加安全控制（暂停、多签、事件）
2. 引入真实税费分发逻辑
3. 增加参数可调但受限的治理接口
4. 修复 `recordTrade` 可被外部滥调用的潜在干扰点

---
（完）
