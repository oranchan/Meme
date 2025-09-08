## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy (模板示例)

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

---

# 代币与流动性合约操作指南 (中文)

本项目包含四个核心合约：

| 合约 | 作用 | 关键点 |
|------|------|--------|
| `MemeToken` | 主 ERC20 代币 (含买/卖/转账差异化税费 + 限制逻辑) | 使用 `_update` 重写实现税费与限频控制 |
| `TradingLimiter` | 交易限制（单笔最大、钱包持仓上限、24h 内次数限制） | 每地址 24h 内最多 20 次，单笔 ≤ 总供应 1%，钱包上限 2% |
| `TaxManager` | 税费计算与账本记录（买 5%，卖 8%，转账 2%） | 分配：40% 市场 / 30% 流动性 / 20% 开发 / 10% 销毁占位 |
| `LiquidityManager` | 初始化创建 Token/WETH Pair 并增加流动性 | 首次 `initLiquidity` 仅限 owner，之后任意人 `addLiquidityETH` |

> 注意：示例仅为演示结构，未包含真实的税费分发/销毁/自动加池等逻辑；主网使用前务必进行安全审计。

## 一、环境准备

1. 安装 Foundry：
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   foundryup
   ```
2. 配置私钥与 RPC：
   ```bash
   export PRIVATE_KEY=0x你的私钥
   export RPC_URL=https://你的RPC
   ```
3. 编译：
   ```bash
   forge build
   ```

## 二、部署顺序建议

`MemeToken` 构造参数：`initialSupply`（基础数量，不含 decimals 扩展）。

1. 部署 `MemeToken`：
   ```bash
   forge create src/MemeToken.sol:MemeToken \
     --rpc-url $RPC_URL \
     --private-key $PRIVATE_KEY \
     --constructor-args 100000000   # 举例：1 亿 (合约内部再乘 10**decimals)
   ```
2. 记录 `MemeToken` 地址（记为 `TOKEN`）。
3. 部署（或获取）UniswapV2 Factory、Router（若在测试网可自部署 / 或使用现成地址）。

### 获取或部署 UniswapV2 组件

#### 1) 使用主网/测试网已有地址（推荐）
- 主网 (Ethereum Mainnet):
  - Factory: `0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f`
  - Router02: `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`
- 其他公链 / 测试网：请到对应链文档或区块浏览器（Explorer）搜索 “UniswapV2Factory” / “UniswapV2Router02” 合约校验地址；若无，则自行部署（见下）。

> 注意：务必确认 Router 版本与 Factory 匹配 (V2)，并确认 WETH 地址正确（不同链的 Wrapped Native Token 地址不同）。

#### 2) 在本地 Anvil 或无官方部署的测试网自建
仓库已引入 `v2-core` 与 `v2-periphery`：
- Factory 源码：`lib/v2-core/contracts/UniswapV2Factory.sol`
- Router 源码：`lib/v2-periphery/contracts/UniswapV2Router02.sol`
- 参考 WETH：`artifacts/WETH9.json` 或 `lib/v2-periphery/buildV1/WETH9.sol`

部署顺序：WETH -> Factory -> Router

(1) 部署 WETH9 (仅本地或需要自建时)：
```bash
forge create lib/v2-periphery/buildV1/WETH9.sol:WETH9 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```
输出地址记为 `WETH`。

(2) 部署 Factory：
```bash
forge create lib/v2-core/contracts/UniswapV2Factory.sol:UniswapV2Factory \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <FEE_TO_SETTER>
```
- `<FEE_TO_SETTER>`：拥有 `setFeeTo` 权限的地址（可用你的部署地址）。
输出地址记为 `FACTORY`。

(3) 部署 Router02：
```bash
forge create lib/v2-periphery/contracts/UniswapV2Router02.sol:UniswapV2Router02 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args <FACTORY> <WETH>
```
输出地址记为 `ROUTER`。

(4) 创建交易对（可选，`LiquidityManager.initLiquidity` 内若不存在会创建）：
```bash
cast send <FACTORY> "createPair(address,address)" <TOKEN> <WETH> \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
返回 `pair` 地址。

(5) 验证 Pair：
```bash
cast call <FACTORY> "getPair(address,address)" <TOKEN> <WETH> --rpc-url $RPC_URL
```

(6) 确认 Router 中的 WETH：
```bash
cast call <ROUTER> "WETH()" --rpc-url $RPC_URL
```
应与部署/查询的 `WETH` 地址一致。

#### 3) 常见问题
- 若调用 Router 的 `addLiquidityETH` 报错：多半是 token 未提前 `approve`，或 Pair 尚未初始化。
- 若 Pair 地址为 0：说明 Factory 中尚未创建；`LiquidityManager.initLiquidity` 会在首次调用时处理。
- 若交易失败但没有明确 revert 信息：使用 `forge debug` 或通过区块浏览器 trace 功能定位。

4. 部署 `LiquidityManager`：
   ```bash
   forge create src/LiquidityManager.sol:LiquidityManager \
     --rpc-url $RPC_URL \
     --private-key $PRIVATE_KEY \
     --constructor-args <TOKEN> <FACTORY> <ROUTER>
   ```
5. （可选）设置 AMM Pair：`MemeToken.setAMMPair(pairAddress, true)` （如果希望买卖时触发不同税率）。

> `TradingLimiter` 与 `TaxManager` 在 `MemeToken` 构造函数内部自动新建，无需单独部署。

## 三、初始化流动性

首次初始化只能由 `LiquidityManager.owner` 调用：

```bash
# 先给 LiquidityManager 授权代币额度
cast send <TOKEN> "approve(address,uint256)" <LIQUIDITY_MANAGER> 1000000000000000000000000 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# 调用 initLiquidity (同时发送 ETH)
cast send <LIQUIDITY_MANAGER> "initLiquidity(uint256)" 500000000000000000000000 \
  --value 10ether \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

流程说明：
1. 合约检测是否已初始化。
2. 查询或创建 Token/WETH Pair。
3. 从 owner 拉取 token（考虑可能的税额，取实际余额）。
4. 包装 ETH -> WETH。
5. Token 与 WETH 转入 Pair 并 `mint` LP 给 owner。

Pair 地址可在调用后读取：`LiquidityManager.pair()`。

## 四、追加流动性

任意用户：
```bash
# 先授权 token 给 LiquidityManager
cast send <TOKEN> "approve(address,uint256)" <LIQUIDITY_MANAGER> 1000000000000000000000 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# 调用 addLiquidityETH (发送 ETH + 指定 token 数量)
cast send <LIQUIDITY_MANAGER> "addLiquidityETH(uint256)" 100000000000000000000 \
  --value 1ether \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

> 移除流动性当前合约未封装，可直接使用 Router 的 `removeLiquidityETH`（先拿到 LP token 并授权给 Router）。

## 五、交易 & 限制规则

| 类型 | 识别方式 | 税率 | 计数记录 | 前置检查 | 后置检查 |
|------|----------|------|----------|----------|----------|
| 买入 | `from` 为 AMM Pair | 5% | `recordTrade(接收者)` | 单笔 ≤1% 总量；接收者余额 <2%；接收者 24h 次数 <20 | 接收者余额仍 <2% |
| 卖出 | `to` 为 AMM Pair | 8% | `recordTrade(发送者)` | 单笔 ≤1%；发送者 24h 次数 <20 | 无（余额限制不对卖出方二次检查） |
| 转账 | 双方都不是 AMM Pair | 2% | 双方各计数 | 单笔 ≤1%；接收者 <2%；双方 24h 次数 <20 | 接收者余额 <2% |

其他说明：
- 24 小时窗基于 `lastTradeTime`，若超过 86400 秒自动重置计数。
- `taxExempt` 地址（可由 owner 设置）跳过全部限制与税费。
- 税额转入 `TaxManager`，仅做内部分类累计，不自动分发。

## 六、常用交互示例

### 设置 AMM 交易对
```bash
cast send <TOKEN> "setAMMPair(address,bool)" <PAIR> true \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### 设置税费豁免
```bash
cast send <TOKEN> "setTaxExempt(address,bool)" <ADDRESS> true \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### 普通转账
```bash
cast send <TOKEN> "transfer(address,uint256)" <TO> 1000000000000000000 \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### 查看最近一次税额
```bash
cast call <TOKEN> "tax()" --rpc-url $RPC_URL
```

### 查看某地址 24h 内已用交易次数
```bash
cast call <TRADING_LIMITER> "tradeCount(address)" <ADDRESS> --rpc-url $RPC_URL
```

## 七、移除流动性 (通过 Router)

假设 LP 代币在 Pair 合约：
1. 查询 LP 余额：`cast call <PAIR> "balanceOf(address)" <YOUR_ADDR>`
2. 授权 Router：
   ```bash
   cast send <PAIR> "approve(address,uint256)" <ROUTER> <LP_AMOUNT> \
     --rpc-url $RPC_URL --private-key $PRIVATE_KEY
   ```
3. 调用 Router：
   ```bash
   cast send <ROUTER> "removeLiquidityETH(address,uint256,uint256,uint256,address,uint256)" \
     <TOKEN> <LP_AMOUNT> 0 0 <YOUR_ADDR> $(($(date +%s)+1800)) \
     --rpc-url $RPC_URL --private-key $PRIVATE_KEY
   ```

## 八、测试本地流程 (Anvil)
```bash
anvil &              # 启动本地链
export RPC_URL=http://127.0.0.1:8545
export PRIVATE_KEY=<anvil默认账户私钥之一>
forge build
# 重复部署+初始化步骤
```

## 九、安全与上线注意事项

- 税费累计未自动分发，需后续实现分配/销毁逻辑。
- 目前没有访问控制的升级机制；如需可引入 Proxy 或模块化设计。
- 注意 `maxTradeAmount` 与 `maxAccountBalance` 固定为部署时总供应的百分比，如后续增发需重新评估逻辑。
- 生产前：
  - 添加 Slither / Mythril / Echidna 等审计工具检测
  - 编写 Forge fuzz 测试覆盖极值
  - 模拟主网流动性与交易行为

## 十、常见问题 (FAQ)

Q: 为什么我转账失败并提示 `Trade amount exceeds limit`？
A: 超过单笔 1% 限制。

Q: 买入时提示 recipient beyond threshold？
A: 接收者持仓 + 净买入后超过 2% 上限。

Q: 频繁操作提示 daily trade limit？
A: 该地址 24 小时窗口内已达 20 次记录。

---

以上为基本使用流程，若需新增功能（自动加池、税费自动分配、黑名单、可调税率等）可在对应合约扩展实现。
