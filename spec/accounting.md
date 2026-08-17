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
| DSH | `inputTokens` = uncached | 独立字段 | `outputTokens` 含 reasoning，`reasoningTokens` 是子集 | 原生 reason 存在时 `Output = output - reason`、`Reason = reasoning`；仅对 DSH 内部的 MiniMax-M3，在原生 reason 缺失时按同一 message 的 `reasoning/text/tool-call.arguments` 字符比例估算；其他缺失场景 `Reason=0`、`Output=raw output` |
| MiniMax Code | `input` = uncached | 独立字段 | 当前账单 output 可能不含可分离 reasoning；reader 用原生字段或 thinking 字符比例拆分 | 能拆分则 `Output/Reason` 守恒；不能拆分则 raw output 全放 `Output`、`Reason=0` |
| Codex | `inputTokens` 含 cache | `cachedInputTokens` 是子集 | output/reasoning 独立 | `Input = max(input - cache, 0)`；Output/Reason 直接映射 |
| Antigravity | event `inputTokens` = uncached | 独立字段 | output/reasoning 独立 | daily 直接映射；sample 保留 cache-inclusive input |
| OpenCode | `tokens.input` = uncached | `tokens.cache.read` 独立 | output/reasoning 独立 | daily 直接映射；sample 保留 cache-inclusive input |
| ZCode / GLM | `model_usage.input_tokens` 含 cache | `cache_read_input_tokens` 是子集 | reader 的 Method A 已将 reasoning 归类 | daily 先减 cache；sample 保留完整 input；不再二次拆分 |

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

## 代码入口

| 责任 | 入口 |
|---|---|
| Harness 原始字段定义 | `Sources/LLM-monitor/Models/TokenAccounting.swift` 的 `TokenAccountingCatalog` |
| Daily 统一字段 | `Sources/LLM-monitor/Models/LocalUsageDaily.swift` |
| Sample → 估算四桶 | `TokenUsageBuckets.fromSample(_:)` |
| Sample → daily 规范化汇总 | `UnifiedTokenUsageAggregator` |
| Sample → 计价三项 | `ModelPricingCatalog.tokenComponents(for:)` |
| DSH raw → daily/sample | `DshLocalUsageScanner.add` |

任何新 harness 必须先补充本矩阵、provider spec 和 `TokenAccountingCatalog`，再接入 UI；
不要在 view 或 pricing 分支里重新猜测 input/cache/reasoning 的关系。
