# Token Accounting Contract

本文定义本项目的统一 token 估算口径。它是 UI、价格估算和跨客户端汇总的边界，
不是对各 provider 原始账本字段的重命名。各 scanner / reader 保留原始字段语义；
只有 `LocalUsageDaily` adapter 和 `TokenUsageBuckets` 规范化层转换为统一口径。

## 统一四个桶

规范化层只输出四个互斥桶：

| 桶 | 含义 |
|---|---|
| `Input` | 未命中 cache 的输入 token（uncached input） |
| `Cache read` | 命中 cache 的输入 token |
| `Output` | 可见输出 token；当 raw output 无法拆分 reasoning 时，保留全部 raw output |
| `Reason` | reasoning token；无法从 raw output 拆分时为 `0` |

`Total tokens = Input + Cache read + Output + Reason`。
`billable output = Output + Reason`，用于价格估算，因为 provider 的输出价通常针对完整
completion，而不是仅可见文字。

`cacheWrite` 不属于统一估算层：它可以保留在 provider 原始 daily/sample 诊断字段中，
但不进入规范化总量、图表、客户端汇总或金额估算。这是有意的估算口径，不代表 provider
账本没有记录它。

## Harness 对齐矩阵

| Harness | raw input | raw cache read | raw output / reasoning | 规范化处理 |
|---|---|---|---|---|
| DSH | `inputTokens` = uncached | 独立字段 | `outputTokens` 含 reasoning，`reasoningTokens` 是子集 | 原生 reason 存在时 `Output = output - reason`、`Reason = reasoning`；仅对 DSH 内部的 MiniMax-M3，在原生 reason 缺失时按同一 message 的 `reasoning/text/tool-call.arguments` 字符比例估算（比例公式已收敛到共享 `ReasoningCharSplit`）；其他缺失场景 `Reason=0`、`Output=raw output` |
| MiniMax Code | `input` = uncached | 独立字段 | 当前账单 output 可能不含可分离 reasoning；reader 用原生字段或 thinking 字符比例拆分 | 能拆分则 `Output/Reason` 守恒（比例公式同样走共享 `ReasoningCharSplit`）；不能拆分则 raw output 全放 `Output`、`Reason=0` |
| Codex | `inputTokens` 含 cache | `cachedInputTokens` 是子集 | output/reasoning 独立 | `Input = max(input - cache, 0)`；Output/Reason 直接映射 |
| Antigravity | event `inputTokens` = uncached | 独立字段 | output/reasoning 独立 | daily 直接映射；sample 保留 cache-inclusive input |
| OpenCode | `tokens.input` = uncached | `tokens.cache.read` 独立 | output/reasoning 独立，但 `tokens.reasoning` 对 `minimax` 前缀恒 0 | native reasoning 原样透传；仅 `minimax` 前缀在 native 为 0 时按 `part` 表字符比例 fallback 分摊（极老库缺 `part` 表时降级为 `Reason=0`，聚合不失败）；daily 直接映射；sample 保留 cache-inclusive input |
| ZCode / GLM | `model_usage.input_tokens` 含 cache | `cache_read_input_tokens` 是子集 | 智谱行由 reader 的 Method A 归类；非智谱分片另有三段式 | daily 先减 cache；sample 保留完整 input；不再二次拆分。智谱行走 Method A 整轮归类；**非智谱分片走字符分摊三段式**：① native `reasoning_tokens > 0` 原样透传 → ② 否则按 `part` 表字符比例分摊（day 级聚合 / 行级样本）→ ③ 都没有保持 `Reason=0` |

## 字段边界

### Raw provider 层

原始模型字段继续按 provider 定义解释。例如 Codex 的
`DailyTokenUsage.inputTokens` 仍是服务端返回的 cache-inclusive input，不能因为 UI
使用 `input` 就把它改名或改存储含义。`cacheWriteTokens` 也继续保留在原始 daily
结构中，便于诊断和未来复核。

### Daily 规范化层

`LocalUsageDaily` 的 `input`、`cacheRead`、`output`、`reasoning` 是统一消费字段。
Codex 在 adapter 中计算 uncached input；其他 provider 的 reader/scanner 已在进入
adapter 前完成对应转换。`totalTokens`、`inputTotal`、`outputTotal` 只使用四个统一桶，
不使用 `cacheWrite`。

### Sample 规范化层

为兼容现有持久化和跨来源合并，`LocalTokenUsageSample.inputTokens` 保持
cache-inclusive，`cachedInputTokens` 保持独立 cache-read。`TokenUsageBuckets.fromSample`
是样本进入价格和汇总计算的唯一转换入口：它把 input 拆成 `Input + Cache read`，并将
`outputTokens` 与 `reasoningOutputTokens` 视为已经互斥的 `Output/Reason`。

### 为什么需要统一汇总器

`UnifiedTokenUsageAggregator` 是 sample 进入日汇总的唯一入口。Settings 页、Provider
卡片和 stale current-day 修复都可能需要从同一批 recent samples 重建当日数据；如果各自
直接相加 `inputTokens`，Codex 的 cache-inclusive input 会被重复计入，或不同入口会对
reasoning / cache 的处理不一致。汇总器先对每个 sample 调用
`TokenUsageBuckets.fromSample(_:)`，再按四个规范化桶累加，因此这些 UI 和修复路径共享
同一套 input/cache/output/reasoning 口径。它只改变规范化汇总，不改写任何 provider 原始
daily 字段或已持久化 sample。

### M3 reasoning 的两条估算路径

DSH 与 MiniMax Code 都只在 provider 没有可用原生 reasoning 数值时估算 M3 的 Reason，
但数据粒度不同：

| Harness | 估算粒度 | 字符来源 | 限制 |
|---|---|---|---|
| DSH | 同一个 `assistant/message` 事件 | `reasoning`、`text`、`tool-call.arguments` 内容块 | 事件级比例估算；内容块缺失时不猜，`Reason = 0` |
| MiniMax Code | 按本地自然日聚合 | `thinking_content`、`msg_content`、`tool_call_args` | token usage 与 message 行无法可靠逐请求配对，只能日级比例估算 |

两条路径都保持 `Output + Reason = raw output`，但结果是估算值，精度受字符与 token
分布差异影响。不要把两种来源的字符统计直接合并，也不要把估算的 Reason 当作 provider
原生账单字段。

两处 M3 字符分摊的**比例公式**共用 `Sources/LLM-monitor/Models/ReasoningCharSplit.swift`
的 `split(outputTokens:reasoningChars:visibleChars:)`（返回 `nil` 表示无法估算，调用方
保持原样）。同一工具还被 ZCode 的非智谱 provider 分片与 OpenCode 的 `minimax` 分片复用，
字符桶口径一致：思考取 reasoning part，可见输出取 text part + tool 参数
（`$.state.input` / DSH `tool-call.arguments`）；粒度分别是 ZCode 分片 day 级聚合 / 行级
样本、OpenCode day 级聚合 / 行级样本。

### 唯一入口：raw → 桶

raw provider 计数器到四个规范化桶的转换**只有一条路径**：
`TokenAccountingCatalog.<harness>.normalizedBuckets(rawInput:cacheRead:rawOutput:rawReasoning:)`。
reader / scanner / aggregation 不得自己写 `input + cacheRead` 或
`rawOutput - reasoning` 这类手算桶关系的表达式。允许的只有两件事：

1. 传给 catalog 的 raw 值做**非负饱和**（`nnClamp` / `max(_, 0)`）；
2. 拿到 `TokenUsageBuckets` 后，按各自持久化结构**重新组装**字段（sample 存
   cache-inclusive `inputTokens`、daily 存 `cacheReadTokens` 等）。

这样 clamping、cache-inclusive 减法、output/reasoning 拆分三处规则只有一份实现；
`testXxxUsage` 系列护栏测试必须全绿，任何手算漂移都会在这些用例上表现为
input/cache/output/reasoning 数值变化。

reader 组装 sample 后仍可能被下游改写（MiniMax 的字符分摊会重建 sample）；此时
catalog 的结果已经在 reader 层固化，重建逻辑必须逐字段原样带回（含
`sourceProviderID` 等诊断字段），不得丢字段。

### 高峰倍率登记表

`ModelPricing.json` 只描述「这个模型多少钱」；「什么时段按几折算」属于正交的另一层，
登记在 `ModelPricingCatalog` 的 `pricingMultipliers` 表里：

| provider | 窗口类型 | 倍率 |
|---|---|---|
| `QuotaProviderID.deepseek` | `PeakWindow` 高峰窗口 | ×2 |

`pricingMultiplier(quotaProviderID:at:)` 遍历登记表求值，未登记的 provider 或窗口未命中
一律返回 1。新增 provider 的峰谷定价只往表里追加一行，不要在求值分支里加
`if quotaProviderID == ...`。价目本身仍然只改 JSON，不在本表登记。

## promptID 命名空间登记表

同一台机器上多份本地账本可能恰好使用相同的 prompt ID（几乎都是裸 `session:turn`）。
不区分来源时它们会被去重成「同一次用户请求」，turns 计数因此偏低。规则集中登记在
`Sources/LLM-monitor/Models/UsageProjectionKernel.swift` 的 `UsageSampleNamespace`：

| 来源（`UsageSampleNamespace` case） | 账本 | 前缀 |
|---|---|---|
| `antigravityNative` | Antigravity native（RPC + .db step 统计） | `antigravity:` |
| `minimaxNative` | MiniMax Code native（v2 runtime-state 单库 SQL） | `minimax-code:` |
| `zcodeNative` | ZCode 智谱系 native（`GlmZcodeLocalUsageScanner`） | `zcode:` |
| `codex` | Codex native（scanner 构造点已自带 `codex:`） | 不叠加 |
| `dsh` | DSH 共享 session 账本 + provider 路由键 | `dsh:<provider>:` |
| `opencode` | OpenCode 一份多 provider 账本 | `opencode:<provider>:` |
| `zcodeSlice` | ZCode 账本里的非智谱 provider 分片 | `zcode:<slice>:` |
| `passthrough` | 显式透传（调用点默认） | 不加 |

**前缀加在投影层**：scanner / reader / 磁盘缓存一律保持账本原始格式，命名空间在帧
构造时（L1 适配层（`HarnessUsageFrame`，逻辑层；类型与 L2 内核同文件 `Models/UsageProjectionKernel.swift`））统一施加。因此旧缓存里的裸 ID 与今天
新写入的裸 ID 得到**完全相同**的终态 ID —— 既有缓存不需要迁移，同一次请求也不会
因为「一份带前缀、一份是裸的」被计成两次。改在 scanner 层加前缀会正好造成这种
双计，不要那样做。

前缀是纯粹的**标识**层：智谱套餐分类（`isGlmOffPeakSample` / `isGlmOtherPlanSample`）
一律按 `sourceProviderID` 判定，`lastPrompt` 等只按 promptID 做等值分组，两者都不
解析 promptID 的字面前缀，所以新增前缀不会影响分类与窗口口径。唯一读前缀的地方是
`LocalUsageSummaryBuilder.isGlmOffPeakSample` 的「OpenCode 合并样本不算闲时」回退
（`hasPrefix("opencode:")`），`zcode:` / `antigravity:` / `minimax-code:` 都不匹配该
判定，语义与加前缀前一致。

## 跨 provider 金额汇总

`ModelCostEstimate` 是**单 provider 内**的计价结果：同一 provider 出现币种冲突时把冲突
模型丢进 unpriced 报「部分计价」，绝不跨币种相加。跨 provider 汇总由第二层
`MixedCurrencyEstimate`（`Sources/LLM-monitor/Models/MixedCurrencyEstimate.swift`）负责：

- 按币种把各 estimate 的 `value` 归集到 `usdTotal` / `cnyTotal`，`value` 或
  `currency` 为 nil 的 estimate 直接跳过；
- 总额 `cnyEquivalentTotal = cnyTotal + usdTotal × usdToCNYRate`（`usdToCNYRate`
  暂硬编码 7，是产品决策而非定价数据）；
- 文案：纯 CNY `¥10.50`、纯 USD `$3.20`、混合 `10（含$1)`（总额无 `¥` 前缀，
  括号内是 USD 原额）。

金额全程用 `Decimal`：`ModelCostEstimate.value` 是浮点累加结果，跨币种还要再乘一次
折算率，用 `Double` 会出现 `0.3 × 7 = 2.0999999…` 的尾差错账。

## 代码入口

| 责任 | 入口 |
|---|---|
| Harness 原始字段定义 | `Sources/LLM-monitor/Models/TokenAccounting.swift` 的 `TokenAccountingCatalog` |
| raw → 四桶（唯一入口） | `TokenAccountingDefinition.normalizedBuckets(rawInput:cacheRead:rawOutput:rawReasoning:)` |
| 高峰倍率登记 | `ModelPricingCatalog.pricingMultipliers` |
| 跨 provider 金额汇总 | `Sources/LLM-monitor/Models/MixedCurrencyEstimate.swift` |
| Daily 统一字段 | `Sources/LLM-monitor/Models/LocalUsageDaily.swift` |
| Sample → 估算四桶 | `TokenUsageBuckets.fromSample(_:)` |
| Sample → daily 规范化汇总 | `UnifiedTokenUsageAggregator` |
| Sample → 计价三项 | `ModelPricingCatalog.tokenComponents(for:)` |
| promptID 命名空间登记 | `Sources/LLM-monitor/Models/UsageProjectionKernel.swift` 的 `UsageSampleNamespace`（前缀常量在 `UsageSampleNamespace.Prefix`） |
| DSH raw → daily/sample | `DshLocalUsageScanner.add` |

任何新 harness 必须先补充本矩阵、provider spec 和 `TokenAccountingCatalog`，再接入 UI；
不要在 view 或 pricing 分支里重新猜测 input/cache/reasoning 的关系。
