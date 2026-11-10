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

用量设置按共享额度池细分展示，一个额度池的 5h / 周窗口不重复计量。分组保留原始模型样本用于定价，权威日桶不由模型明细反算；日桶与留存样本的非负差额单列为未归属额度池，不伪造模型、金额或速度。Antigravity 与 Agy 共享 Gemini / Argon / Claude-GPT 的额度池分类，ZCode 仍按账本 provider 的 Coding Plan / Start Plan 等分类。

各 Harness 的用量按实际账本 provider 自动归因：native 帧直接使用 `quotaProviderID`，多 provider 账本使用内置 `ClientProviderBinding.defaultBindings` 别名表。归因不再有用户开关，旧配置中的关闭值不参与计算；同一来源只按现有分片规则计入对应 Provider，不跨卡重复累加。无法识别的 provider 保留未归属，不依据模型名猜测额度池。

| Harness | raw input | raw cache read | raw output / reasoning | 规范化处理 |
|---|---|---|---|---|
| DSH | `inputTokens` = uncached | 独立字段 | `outputTokens` 含 reasoning，`reasoningTokens` 是子集 | 原生 reason 存在时 `Output = output - reason`、`Reason = reasoning`；仅对 DSH 内部的 MiniMax-M3，在原生 reason 缺失时按同一 message 的 `reasoning/text/tool-call.arguments` 字符比例估算（比例公式已收敛到共享 `ReasoningCharSplit`）；其他缺失场景 `Reason=0`、`Output=raw output` |
| MiniMax Code | `input` = uncached | 独立字段 | 当前账单 output 可能不含可分离 reasoning；reader 用原生字段或 thinking 字符比例拆分 | 能拆分则 `Output/Reason` 守恒（比例公式同样走共享 `ReasoningCharSplit`）；不能拆分则 raw output 全放 `Output`、`Reason=0` |
| Codex | `inputTokens` 含 cache | `cachedInputTokens` 是子集 | output/reasoning 独立 | `Input = max(input - cache, 0)`；Output/Reason 直接映射 |
| Antigravity | event `inputTokens` = uncached | 独立字段 | `outputTokens` **含思考**（`thinkingOutputTokens` 是子集；实测全量事件 100% 满足 `outputTokens == thinking + response`） | catalog `output: .reasoningIncluded`：`Output = rawOutput − thinking`、`Reason = thinking`，四桶守恒（修掉历史思考双重计量）；daily 与 sample 同经 catalog 统一；sample 保留 cache-inclusive input |
| agy | transcript `input_tokens` = uncached | 独立字段 | `output_tokens` 含思考，无原生 reasoning 计数 | `thinking` 非空时按字符占比走共享 `ReasoningCharSplit` 守恒拆分（`Reason + Output = raw output`）；无 thinking 则 `Reason=0`、`Output=raw output`；daily 直接映射；sample 保留 cache-inclusive input。agy 在 `TokenAccountingCatalog` 里没有独立条目，计数口径与 `antigravity` 一致，在 reader 层直接映射（见「唯一入口」的例外说明） |
| OpenCode | `tokens.input` = uncached | `tokens.cache.read` 独立 | output/reasoning 独立，但 `tokens.reasoning` 对 `minimax` 前缀恒 0 | native reasoning 原样透传；仅 `minimax` 前缀在 native 为 0 时按 `part` 表字符比例逐调用 fallback 分摊（极老库缺 `part` 表时降级为 `Reason=0`，聚合不失败）；daily output/reasoning 从同窗口样本按日累计；sample 保留 cache-inclusive input |
| ZCode / GLM | `model_usage.input_tokens` 含 cache | `cache_read_input_tokens` 是子集 | 原生 `reasoning_tokens` 列实测 0 行有值；reasoning 来自 part 表字符 | daily 先减 cache；sample 保留完整 input；不再二次拆分。**智谱行与非智谱分片统一字符分摊三段式**（2026-11-08 起，Method A 整轮归类废止——实测思考行 100% 同时含可见 text、`output_tokens` 含思考）：① native `reasoning_tokens > 0` 原样透传 → ② 否则按 `part` 表字符比例**行级**分摊 → ③ 都没有保持 `Reason=0`。**日聚合的 output/reasoning 直接取行级分摊的按日累计**（同日二次修订：日级 / 行级双轨经 `includingCurrentDay` 逐桶 max() 会凭空膨胀，触发「明细采样已达上限」误报） |

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

**样本完整性与 daily 的关系（两条独立截断标志）**：`HarnessUsageFrame.isTruncated`
是来源快照统计口径被截断（如 DSH 文件数/字节预算挤出最旧 session）；`samplesTruncated`
（当前唯一置位来源是 DSH 的 `recentSamplesLimit` 保留上限，经
`DshProviderUsage.recentSamplesTruncated` 冒泡）表示 model/window 级样本被挤出但
**每日合计不变**。样本被截断时 per-model 明细与窗口金额来自留存样本、可能不完整，
每日合计仍以 daily 四桶为权威；两标志在投影中独立透传、按「任一来源置位即置位」合并。

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
| MiniMax Code | 已配对调用逐行，未配对残余按本地自然日 | `thinking_content`、`msg_content`、`tool_call_args` | 配对调用用本行字符；未配对样本仅分配扣除配对/原生 reasoning 后的日残余预算，并保留整数舍入余数；daily output/reasoning 从最终样本累计 |

两条路径都保持 `Output + Reason = raw output`，但结果是估算值，精度受字符与 token
分布差异影响。不要把两种来源的字符统计直接合并，也不要把估算的 Reason 当作 provider
原生账单字段。

两处 M3 字符分摊的**比例公式**共用 `Sources/LLM-monitor/Models/ReasoningCharSplit.swift`
的 `split(outputTokens:reasoningChars:visibleChars:)`（返回 `nil` 表示无法估算，调用方
保持原样）。同一工具还被 ZCode 的非智谱 provider 分片、OpenCode 的 `minimax` 分片与
agy 的 transcript 行复用，字符桶口径一致：思考取 reasoning part（agy 取行内
`thinking` 字段），可见输出取 text part + tool 参数（`$.state.input` / DSH
`tool-call.arguments` / agy `content` + `tool_calls` 序列化文本）；粒度分别是 ZCode
分片行级样本（daily 同源累计）、OpenCode 行级样本（daily 同源累计）、agy 行级样本。

OpenCode 与 MiniMax Code 的 daily output/reasoning 必须与同窗口样本按日累计逐桶
一致（缓存分别 v3 / v21）。MiniMax 同日原生 reasoning 只固定对应调用，不能短路其他调用的字符回退；原生与字符配对调用的账面 output 及已知字符先从日预算扣除，未配对调用仅分配残余。投影的 `includingCurrentDay` 逐桶 max 只修补真实滞后，
不能用于协调两套不同的拆分；否则它会分别挑出偏大的 output 与 reasoning、凭空增量。

### 唯一入口：raw → 桶

raw provider 计数器到四个规范化桶的转换**只有一条路径**：
`TokenAccountingCatalog.<harness>.normalizedBuckets(rawInput:cacheRead:rawOutput:rawReasoning:)`。
reader / scanner / aggregation 不得自己写 `input + cacheRead` 或
`rawOutput - reasoning` 这类手算桶关系的表达式。允许的只有两件事：

1. 传给 catalog 的 raw 值做**非负饱和**（`nnClamp` / `max(_, 0)`）；
2. 拿到 `TokenUsageBuckets` 后，按各自持久化结构**重新组装**字段（sample 存
   cache-inclusive `inputTokens`、daily 存 `cacheReadTokens` 等）。

**上游异常（cacheRead > rawInput）的统一裁定**：
在 cache-inclusive 口径（Codex / ZCode）下，raw input 代表包含缓存与未命中输入的总包络。当上游账单或遥测异常导致 `cacheRead > rawInput` 时，catalog 统一执行饱和截断：
`effectiveCacheRead = min(safeCacheRead, safeInput)`，`uncachedInput = 0`。
四桶总和守恒为 `safeInput + output + reasoning`，既杜绝负 uncached input，又防止 cacheRead 越界膨胀导致 totalTokens 虚高。`GlmZcodeDBReader` 的智谱主表与分片聚合已完全收拢至 `TokenAccountingCatalog.zcode.normalizedBuckets`，不再手算。

例外（当前实现的既成事实，不要照抄）：agy 的 transcript 行在 `AgyLocalUsageAggregation` 内直接组装四桶。新增 harness 必须走 catalog。

这样 clamping、cache-inclusive 减法、output/reasoning 拆分三处规则只有一份实现；
`Tests/LLMMonitorTests/TokenAccountingTests.swift`（`testAllHarnessDefinitionsProduceDisjointNormalizedBuckets`
等）必须全绿，任何手算漂移都会在这些用例上表现为 input/cache/output/reasoning
数值变化。

reader 组装 sample 后仍可能被下游改写（MiniMax 的字符分摊会重建 sample）；此时
catalog 的结果已经在 reader 层固化，重建逻辑必须逐字段原样带回（含
`sourceProviderID` 等诊断字段），不得丢字段。

### 高峰倍率登记表

`ModelPricing.json` 只描述「这个模型多少钱」；「什么时段按几折算」属于正交的另一层，
登记在 `ModelPricingCatalog` 的 `pricingMultipliers` 表里：

| provider | 窗口类型 | 倍率 |
|---|---|---|
| `QuotaProviderID.deepseek` | `PeakWindow` 高峰窗口 | `PeakWindow.multiplier`，默认 ×2；可由 Provider JSON 改为 ×1.5、×3 等 |

默认判定口径为 Rule A：工作日（周一–周五 ∧ 非法定节假日，节假日表来自
`HolidayCalendar.shared`）内命中高峰窗口才乘倍率——**法定节假日的周一–周五
不算高峰、不加倍**；调休上班的周六/周日同样不算高峰。Provider 的 `peakWindow` 可覆盖时段、`weekdaysOnly` 与倍率；`weekdaysOnly: false` 时每天按指定时段计价。
`pricingMultiplier(quotaProviderID:at:deepseekPeakWindow:holidays:)` 遍历登记表求值，
未登记的 provider 或窗口未命中一律返回 1。新增 provider 的峰谷定价只往表里追加
一行，不要在求值分支里加 `if quotaProviderID == ...`。登记表只决定哪些 Provider 参与金额倍率计算，倍率值取传入窗口的 `multiplier`；模型基础价仍只改 `ModelPricing.json`。

**口径说明（勿混入积分套餐类）**：GLM（zhipu）的价值为**名义估算、与峰谷无关**
——峰谷对 GLM 只影响高峰提示 pill 与健康色（卡头点 floor），不参与价值系数；
倍率表只登记按量计费类 provider（当前仅 DeepSeek），勿给积分套餐类 provider
（GLM Coding Plan 这类共享积分池）加价值系数。

## Token/s 速率口径（解码速度，2026-11-08 起分母扣除 TTFT）

token 速率（tok/s）只在 sample 级定义，不进入帧 / 投影内核：分子 = `Output + Reason`
（billable output，与四桶规范化同源）；分母 = **解码时长 = 单次调用完整时长 − 首字延迟**
（2026-11-08 起；此前是含 TTFT 的完整时长）。调用时长由各家 reader 写入
`LocalTokenUsageSample.durationSeconds`（可选字段，旧缓存解码得 nil），首字延迟在
`ttftSeconds`（见下节）；**无 TTFT 的调用按 0 计——时长全额计入解码**（用户裁定），
`ttft ≥ duration` 的异常样本整条剔除。窗口聚合 = Σ分子 ÷ Σ解码时长，**唯一实现在
`LocalUsageSummaryBuilder.windowTokenRate`**（`Models/LocalTokenUsageSample.swift`）；
有效性域 duration ∈ [0.2, 3600] s 且解码时长 > 0，缺失或越界的样本分子分母都不计
——宁出 `—` 不出假平均。Prompt 级分布（`promptSpeedStatistics`，Harness 列表 Speed
列与 7 天历史用）同口径：任一调用解码时长非正 → 整个 prompt 不进分布（沿用
「宁缺毋假」门控），Prompt 速率 = Σtokens ÷ Σ解码时长。混合覆盖窗口（部分调用无
TTFT）的读数介于解码速度与含 TTFT 速度之间，tooltip 已注明「无 TTFT 数据的调用
按时长全额计入」。

| Harness | durationSeconds 来源 |
|---|---|
| ZCode | `model_usage.duration_ms` 显式列（主表与非智谱分片同口径） |
| OpenCode | `data.time.completed − time_created`（data JSON 内嵌双时间戳） |
| DSH | `assistant/message.time − step/start.time` 差分（工具执行在 message 之后，结构上不混入） |
| Codex | `token_usage_record` 混合差分：发起锚 = max(上一条 `token_count` 时刻, 上一条 record 时刻)，回退 `task_started`；token 计量保持 `token_count` 单源，record 只计时（详见 `harnesses/codex.md` Rules） |
| Antigravity | 方案 B：纯文本流式输出（`!isToolCall && f12 >= 0.5s`）供给 `(ttftSeconds ?? 0) + streamingSeconds`（解码分母 `duration − ttft` 恒等于 `f12`）；工具调用或短流式为 `nil`（避免除零虚高）；无 `gen_metadata` 夹具回退 `steps` 表 `f7 − f1` 差分；缓存 v12 重建 |
| MiniMax | `local_runtime_message_rows.$.usage.request_duration_ms`（独立守门窗口查询 + `(session, turn)` FIFO 配对、以 input/output tokens 核对回填；缓存 v16。**禁止** `created_at_ms` 差分——toolUse 行记录的是工具完成时刻，会把工具耗时算入） |
| agy | 方案 B：`conversations/<session>.db` 的 `llmCallTimingByStepIndex` 供给（纯文本流式 `(ttft ?? 0) + streaming`，工具调用 `nil`；无 gen_metadata 回退 steps 差分）；.db 缺失时降级 transcript 后继 `MODEL:GENERIC` 锚点差分（秒级，约 94% 覆盖）；缓存 v8 重建；已有原生 timing 明确排除的调用不得再走 GENERIC fallback。**禁止**前驱行差分——transcript `created_at` 是发起时刻 ⌊f1⌋，差分量的是调度延迟/上轮工具耗时 |

上游 TTFT 字段可得性（2026-11-08 调研落地，见下节）：ZCode `model_usage`
原生 `time_to_first_token_ms`（逐调用，71% 覆盖，缺口行 nil）、Codex `task_complete` payload 原生
`time_to_first_token_ms`（turn 级，回填 turn 首调）；Antigravity 与 agy 采用**方案 B**：
`gen_metadata` 的 `f1.f11` 作为首字延迟 TTFT（中位数 ~3.0s - 4.6s，包含 prefill 与内部思考）；
流式纯文本输出由 `f1.f12`（流式解码耗时）配合给出真实吞吐，工具调用 duration 置 nil；详见
[`providers/antigravity.md`](providers/antigravity.md) § TTFT / streaming 时长字段；DSH 无显式字段、**三代账本均可
推导**——v1 取首个独立 `assistant/chunk.time − step/start.time`，v3 / v4 取
`assistant/message.data.stream[]` 首条 `time` 同锚点差分（初版调研漏看
message.data.stream 误判 v3 / v4 不可得，同日复核修订；实测 v3 1094/1094、
v4 70/70 可差分，见 [`harnesses/dsh.md`](harnesses/dsh.md) § TTFT 调研记录）；
MiniMax Code 由 **`request_duration_ms − decode_duration_ms` 差分推导**（初版调研
漏了 `decode_duration_ms` 键误判不可得、曾显式写 0；全库 14,665 行实测覆盖 94.5%、
差值非负 99.1%，见 [`harnesses/minimaxcode.md`](harnesses/minimaxcode.md) § TTFT 调研记录）；
OpenCode 无字段（恒 nil，
UI 显示 `—`）——调研记录见
[`harnesses/zcode.md`](harnesses/zcode.md) /
[`harnesses/codex.md`](harnesses/codex.md) /
[`providers/antigravity.md`](providers/antigravity.md)。

## TTFT 口径（首字延迟，sample 级）

TTFT 与 token 速率同层：只在 sample 级定义、不进入帧 / 投影内核，由各家 reader 写入
`LocalTokenUsageSample.ttftSeconds`（可选字段，秒；旧缓存解码得 nil）。**有效性域
[0, 3600] s 且有限**——与 duration 的 [0.2, 3600] 不同，**0 是合法值**（真实 0ms
读数不被过滤；2.5.3 曾以「MiniMax Code 显式写 0」为背景，2.5.4 起 MiniMax 改差分
推导，规则本身不变）；负值 / 非有限 / 越界的样本不计。聚合函数唯一实现在
`LocalUsageSummaryBuilder`（`Models/LocalTokenUsageSample.swift`）：

| 聚合 | 函数 | 口径 |
|---|---|---|
| 调用级 P50 | `callTTFTStatistics`（`CallTTFTStatistics.p50`） | 有效样本排序取中位（偶数取中间均值）；Harness 列表行 / 段与 7 天历史的每日值用此口径 |
| 窗口均值 | `windowTTFTMeanSeconds` | Σ有效 ttft ÷ Σ有效调用数（每次调用等权，0 参与）；「额度窗口」用量态 TTFT 列用此口径 |
| 多池合并中间量 | `windowTTFTComponents` | (Σttft, 调用数)，`combineWindowUsage` 按 Σsum ÷ Σcount 合并（模式同速率 Σ/Σ），缺中间量的窗口不参与 |

| Harness | ttftSeconds 来源 |
|---|---|
| ZCode | `model_usage.time_to_first_token_ms` 显式列 ÷ 1000（主表与非智谱分片同口径；NULL-aware 读取，NULL → nil；缓存 v12 重建） |
| Codex | `task_complete` payload `time_to_first_token_ms` ÷ 1000，turn 级 → 回填该 turn **第一条** `token_usage_record` 样本（文件内配对，turn_id 全局 UUID 不跨文件；缓存 v2 重建） |
| Antigravity | 方案 B：`.db` 的 `gen_metadata` 解析 `f1.f11` Duration 秒数（中位数 ~3.0s - 4.6s）；缓存 v12 重建 |
| agy | 方案 B：同 Antigravity，经 `AntigravityStepTimestampReader.llmCallTimingByStepIndex` 从 `.db` 读取 `f1.f11`；v7 接入，当前缓存 v9 保留小数秒后重建 |
| DSH | 双路径：v1 首个独立 `assistant/chunk.time − step/start.time` ÷ 1000（字节级预过滤 + 每 step 首 chunk 节流解码）；v3 / v4 取 `assistant/message.data.stream[]` 首条 `time` 同锚点差分（缓存 v7 重建。见 `harnesses/dsh.md` § TTFT 调研记录） |
| MiniMax | `(request_duration_ms − decode_duration_ms) / 1000`（同一时长守门窗口查询补取 decode 键、同一 `(session, turn)` FIFO 配对；decode 缺失 / 差值 < 0 → nil。缓存 v18 重建。见 `harnesses/minimaxcode.md` § TTFT 调研记录） |
| OpenCode | 无（恒 nil） |

fleet 行的远端上报无 TTFT，TTFT 列显示 `—`（wire 协议未扩展）。

多额度池合并（`combineWindowUsage`）按 Σ分子 / Σ时长 相加后再除；合并产物带
`rateNumerator` / `rateDenominator` 中间量，多层合并不丢精度，缺中间量的手工构造
窗口不参与速率加权。fleet 行的远端上报无时长，速度列显示 `—`（wire 协议未扩展）。

UI 消费：「额度窗口」模块**用量态**的速度列从「价值」位换为「速度」（`speedCell`；
**分析态仍显示价值**；2026-11-08 起 TTFT 列插在 Reason 与速度之间、用量态 7→8 列，
速度列改用独立 30pt 窄列 `usageSpeedColumnWidth`，详见 `spec/ui/edge-dock.md`）。`speedText` 转用统一 `Formatters.formatSpeed`：
数值部分含小数点最多三个字符（`8.6` / `50` / `246`），舍入跨档后不保留多余小数；
将进位到四位时使用 K / M / G 数量级后缀（后缀不计入数值宽度），更大数量级使用指数后缀。
nil、负值或非有限读数显示 `—`。菜单摘要与七天速度趋势复用同一格式（原模型行
Prompt 速度范围线 UI 已于 2026-11-07 移除，统计层保留；见 §Prompt 速度分布）；表头 tooltip
注明口径「窗口内 (Output+Reason) ÷ 解码时长，tok/s；解码时长 = 调用时长 − 首字延迟，
无 TTFT 数据的调用按时长全额计入」（2026-11-08 起分母扣除 TTFT，见 §Token/s 速率口径）。
TTFT 的三处 UI 消费（2026-11-08）：Harness 列表 Speed 与 Value 之间（调用级 P50，
`Formatters.formatTTFT`）、「额度窗口」用量态 Reason 与速度之间（窗口均值）、7 天用量
历史命中与速度之间（每日调用级 P50，单位秒）；格式统一走 `Formatters.formatTTFT`
（裸数字秒 `0.86` / `12.5` / `124`，nil → `—`）。
今 / 闲 / 免 / 速 / 它行速率与金额用同一批样本（`todaySamples` / `offPeakTodaySamples` /
`glmCategoryTodaySamples`）。

## Prompt 速度分布（菜单用量）

菜单用量的速度分布以 `promptID` 为最小统计单位，由
`LocalUsageSummaryBuilder.promptSpeedStatistics` 计算。多个 sample 共享一个命名空间化
`promptID` 时表示一次用户请求中的多轮模型调用：先合并这些调用的
`Output + Reason` 与有效时长，再算该 prompt 的速度 `Σ(Output+Reason) ÷ Σ时长`；
这样一次多轮 prompt 只在分布中占一个样本，不会因轮数较多而加权。

有效时长仍采用调用级的 `[0.2, 3600]` 秒边界，并要求有限数值。一个 prompt 中只要有
任一调用的时长缺失、越界或非有限，该 prompt 就整体不进入 min / max / P50 分布，避免
将部分 token 与部分时长冒充完整 prompt 速度。`validPromptCount` / `totalPromptCount`
供 UI 披露覆盖率；没有有效 prompt 时 min、max、P50 都为 nil。

`latest` 取 `completedAt` 最新的 prompt，即使该 prompt 时长无效也返回 nil，不回退到更旧
的有效 prompt。若多个 prompt 的最新时间相同，按 `promptID` 字典序升序稳定打破并列。
P50 为有效 prompt 速度的中位数；偶数个样本时取中间两个速度的算术平均。输出为零但
时长完整的 prompt 是有效样本，速度为 `0 tok/s`。

菜单客户端段的统计覆盖该 client 当日全部本地样本；模型行则只覆盖同一
`quotaProviderID + modelName` 行的当日样本。两者都只使用本地 sample；fleet 未上报调用时长，
不构造 prompt 速度。原 `tokensPerSecond` / `windowTokenRate` 调用级加权窗口速度继续保留，
新分布独立提供 min / max / P50 / latest，不改变额度窗口速度和价格、token 桶或日归桶口径。

## 七天历史趋势

七天历史图的七种单选指标为总量、Rounds、价值、思考、产出、命中、速度。
总量严格为规范化四桶之和（Input + Cache + Output + Reason），不含诊断字段 `cacheWrite`；
Rounds 是模型 API call 数；命中率为 `cacheRead / (input + cacheRead)`，思考占比为 `reasoning / (output + reasoning)`，
产出比为 `(output + reasoning) / (input + cacheRead)`。每次选择只使用所选指标自身的线性 Y 轴，
图表固定保留最近七个自然日日槽。逐日明细表格采用「6 个基础列（日期、R/T、Input、Cache、Reason、Output）+ 选中的动态指标列」，
固定呈现 7 列数据。现存 daily 行里的零是已知零；缺少 daily 行表示未知，折线在
该槽断开；当前日标注为未完结。历史指标选择独立于额度窗口的「分析 / 用量」选择。

价值图使用 `ModelCostEstimate.value` 与 `currency` 数值字段，不从格式化文案逆向解析。若七日内
出现多种币种，整条价值序列统一换算为 CNY（USD 使用 `MixedCurrencyEstimate.usdToCNYRate`）；
单币种序列保留原币种。部分计价、样本截断或来源日估价标记必须随价值数据披露。每日速度图
只展示 `LocalUsageSummaryBuilder.promptSpeedStatistics` 的 P50；Fleet 无本地调用时长样本时
速度不可用。每日权威 token 桶不因样本截断而变成部分值，但样本推导的价值 / 速度需标为部分。
有效 Prompt 少于已记录 Prompt 时，P50 同样标注部分样本（缺少有效时长的 Prompt 不参与分布）。
设置客户端页的 `ClientProviderUsageSummary.samplesTruncated` 沿投影传递样本覆盖状态，
与日桶源级 `isTruncated` 分开保留；两者都会影响样本推导指标的完整性提示。

## promptID 命名空间登记表

同一台机器上多份本地账本可能恰好使用相同的 prompt ID（几乎都是裸 `session:turn`）。
不区分来源时它们会被去重成「同一次用户请求」，turns 计数因此偏低。规则集中登记在
`Sources/LLM-monitor/Models/UsageProjectionKernel.swift` 的 `UsageSampleNamespace`：

| 来源（`UsageSampleNamespace` case） | 账本 | 前缀 |
|---|---|---|
| `antigravityNative` | Antigravity native（RPC + .db step 统计） | `antigravity:` |
| `minimaxNative` | MiniMax Code native（v2 runtime-state 单库 SQL） | `minimax-code:` |
| `zcodeNative` | ZCode 智谱系 native（`GlmZcodeLocalUsageScanner`） | `zcode:` |
| `agy` | agy CLI 本地 transcript（单源账本，裸 `session:step:N`） | `agy:` |
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
一律按 `sourceProviderID` 判定，其余对 promptID 的使用（如 DSH 去重键）只做等值分组，
都不解析 promptID 的字面前缀，所以新增前缀不会影响分类与窗口口径。唯一读前缀的地方是
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
| 窗口 token 速率（唯一入口） | `LocalUsageSummaryBuilder.windowTokenRate` + `QuotaWindowUsageSnapshot.Window.tokensPerSecond`（`Models/LocalTokenUsageSample.swift`） |
| 跨 provider 金额汇总 | `Sources/LLM-monitor/Models/MixedCurrencyEstimate.swift` |
| Daily 统一字段 | `Sources/LLM-monitor/Models/LocalUsageDaily.swift` |
| Sample → 估算四桶 | `TokenUsageBuckets.fromSample(_:)` |
| Sample → daily 规范化汇总 | `UnifiedTokenUsageAggregator` |
| Sample → 计价三项 | `ModelPricingCatalog.tokenComponents(for:)` |
| promptID 命名空间登记 | `Sources/LLM-monitor/Models/UsageProjectionKernel.swift` 的 `UsageSampleNamespace`（前缀常量在 `UsageSampleNamespace.Prefix`） |
| DSH raw → daily/sample | `DshLocalUsageScanner.add` |

任何新 harness 必须先补充本矩阵、provider spec 和 `TokenAccountingCatalog`，再接入 UI；
不要在 view 或 pricing 分支里重新猜测 input/cache/reasoning 的关系。

> 核对基线：2026-11-10 · 代码 abcf932
